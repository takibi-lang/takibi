#!/usr/bin/env bash
# Give each concurrent clone of this repository its own block of QEMU lane
# ports. Sourced by every runner that claims ports from the port guard.
#
# The lane port numbers are fixed constants, and every clone's containers share
# one host network namespace, so two clones running lanes at the same time bind
# the same ports. scripts/qemu_port_guard.py (issue #407) reports that at
# runtime, and scripts/check_qemu_lane_ports.py checks the lanes against each
# other, but neither can separate two clones: their claims are identical by
# construction.
#
# A uniform additive offset separates them. Every lane in a session moves by
# the same amount, so claims that were disjoint stay disjoint and both existing
# checks keep their meaning; the declared defaults remain the single-session
# numbers the scripts and the Makefile already document.
#
# The offset comes from a block number, and a block is claimed under the
# session's own name in a registry shared by every container. A name-keyed
# registry rather than a hash of the name: with the block count below, hashing
# a dozen session names collides with near-certainty, and a probe of what is
# currently bound cannot separate two sessions that are simply idle.
#
# The registry survives an interrupted make. `flock` is held by an open file
# description, so the kernel releases it when the holder dies for any reason,
# including SIGINT; the lock is held only across the read-modify-write, never
# across a QEMU run; and the file itself is replaced by rename(2), so a reader
# sees either the whole previous content or the whole new content.

# One block is wide enough for every lane port, and the highest block must stay
# below the ephemeral range. scripts/check_qemu_lane_ports.py enforces both
# against the real lane claims, so a lane added outside this window turns a
# build red rather than colliding at runtime.
QEMU_SESSION_PORT_STRIDE=1400
QEMU_SESSION_PORT_BLOCKS=11
QEMU_SESSION_EPHEMERAL_FLOOR=32768

# scripts/repeat_kernel_lane.sh gives each sample of a repeated lane ports of
# its own, so one sample cannot inherit the previous one's lingering sockets.
# Those ports live above the declared lane ports and inside the same block, so
# a session's whole port footprint still moves as one offset. A base chosen
# outside the block would land in the next session's, which is why the base is
# defined here rather than typed on a command line.
QEMU_SESSION_REPEAT_BASE=18720
QEMU_SESSION_REPEAT_STEP=8
QEMU_SESSION_REPEAT_MAX_SAMPLES=56

qemu_session_registry_dir() {
    printf '%s\n' "${TAKIBI_SESSION_REGISTRY:-$HOME/.takibi-sessions}"
}

# Claim this session's block, or report the one it already holds.
qemu_session_claim_block() {
    local session="$1"
    local dir registry lock tmp block line used

    dir="$(qemu_session_registry_dir)"
    registry="$dir/blocks"
    lock="$dir/lock"

    # Held for the read-modify-write only. The subshell owns the descriptor, so
    # it is closed on return and cannot disturb a runner's own fd 9 lock.
    (
        exec 8>"$lock" || exit 1
        flock 8

        [ -e "$registry" ] || : >"$registry"

        used=""
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                [0-9]*" "*) ;;
                *)
                    echo "FAIL qemu-session-ports: $registry has a line that is" \
                         "not 'BLOCK SESSION': $line" >&2
                    exit 1
                    ;;
            esac
            if [ "${line#* }" = "$session" ]; then
                printf '%s\n' "${line%% *}"
                exit 0
            fi
            used="$used ${line%% *}"
        done <"$registry"

        block=0
        while [ "$block" -lt "$QEMU_SESSION_PORT_BLOCKS" ]; do
            case " $used " in
                *" $block "*) block=$((block + 1)) ;;
                *) break ;;
            esac
        done
        if [ "$block" -ge "$QEMU_SESSION_PORT_BLOCKS" ]; then
            echo "FAIL qemu-session-ports: all $QEMU_SESSION_PORT_BLOCKS port" \
                 "blocks are claimed in $registry; remove a retired session" >&2
            exit 1
        fi

        tmp="$registry.tmp.$$"
        cat "$registry" >"$tmp"
        printf '%s %s\n' "$block" "$session" >>"$tmp"
        mv "$tmp" "$registry"
        printf '%s\n' "$block"
    )
}

# Echo the port offset for this session. Zero when nothing selects one, which
# is the unchanged single-session behaviour a contributor and CI both get.
qemu_session_port_offset() {
    local session block

    if [ -n "${TAKIBI_QEMU_PORT_OFFSET:-}" ]; then
        case "$TAKIBI_QEMU_PORT_OFFSET" in
            ''|*[!0-9]*)
                echo "FAIL qemu-session-ports: TAKIBI_QEMU_PORT_OFFSET must be" \
                     "a non-negative integer, not '$TAKIBI_QEMU_PORT_OFFSET'" >&2
                return 1
                ;;
        esac
        printf '%s\n' "$TAKIBI_QEMU_PORT_OFFSET"
        return 0
    fi

    session="${TAKIBI_SESSION:-}"
    if [ -z "$session" ] || [ ! -d "$(qemu_session_registry_dir)" ]; then
        printf '0\n'
        return 0
    fi
    case "$session" in
        *[!A-Za-z0-9._-]*)
            echo "FAIL qemu-session-ports: TAKIBI_SESSION may contain only" \
                 "letters, digits, dot, underscore and dash: '$session'" >&2
            return 1
            ;;
    esac

    block="$(qemu_session_claim_block "$session")" || return 1
    printf '%s\n' "$((block * QEMU_SESSION_PORT_STRIDE))"
}

# Shift the named port variables in place. One call per lane, naming exactly
# the ports that lane claims, so the lane's port set is written down once.
qemu_session_shift_ports() {
    local offset name current

    offset="$(qemu_session_port_offset)" || exit 1
    if [ "$offset" -eq 0 ]; then
        return 0
    fi

    for name in "$@"; do
        eval "current=\${$name:-}"
        case "$current" in
            ''|*[!0-9]*)
                echo "FAIL qemu-session-ports: \$$name is not a port number" \
                     "('$current')" >&2
                exit 1
                ;;
        esac
        eval "$name=\$((current + offset))"
    done

    if [ "${TAKIBI_QEMU_PORT_VERBOSE:-0}" = 1 ]; then
        echo "[qemu-session-ports] ${TAKIBI_SESSION:-(none)} offset=+$offset" >&2
    fi
}
