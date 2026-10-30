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
#
# A row says who last used a block, not who is using it. What says a block is
# in use is a lease: a runner holds a shared flock on leases/<session> from
# before its claim until it and every child that inherited the descriptor,
# QEMU included, have exited. The kernel drops the lock however they die, so
# the lease cannot go stale, and flock already is what this registry trusts
# between containers. When every block has a row, a claim takes over the block
# of a session whose lease is free: an idle worktree must not refuse every lane
# (2026-10-30: over an hour of "all blocks are claimed" with no lane running).
# A row with no lease file was written by a checkout older than the lease, whose
# lane cannot be seen running, so it is never taken over.

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
#
# The base is boxed in from BOTH sides, and the box is narrow. It must stay
# above the highest declared lane port -- 18733, the settings-wake control
# lane (GitHub issue #635), which is what moved this from 18725; before that
# 18724, the affinity lane's reap mode (GitHub issue #571), had moved it from
# 18724 -- and the window's top must stay inside the block, whose last port is
# measured from the LOWEST declared port: 17773 + 1400 - 1 = 19172, so with 54
# samples of 8 the base cannot exceed 18741. It is 18734 today: the
# next lane added at this end does not narrow the box, it empties it, and the
# fix will be to raise the block stride rather than the base.
# check_qemu_lane_ports.py turns the build red rather than letting a repeated
# sample bind a lane's own port at runtime.
QEMU_SESSION_REPEAT_BASE=18734
QEMU_SESSION_REPEAT_STEP=8
QEMU_SESSION_REPEAT_MAX_SAMPLES=54

qemu_session_registry_dir() {
    printf '%s\n' "${TAKIBI_SESSION_REGISTRY:-$HOME/.takibi-sessions}"
}

# Claim this session's block, or report the one it already holds.
#
# $2 and $3, when given, are this container's base name and the names of the
# linked worktrees that exist right now. A row "<base>-wt-<name>" whose
# worktree is gone is dropped here: a worktree removed without
# qemu_session_release_block (an agent's isolated worktree cleaned up by its
# harness, a `git worktree remove` by hand) otherwise kept its block for
# good, and the registry filled until every lane failed with "all blocks are
# claimed" (2026-10-26). Rows of other containers are not pruned, since this
# repository cannot say whether their worktrees exist; only a free lease can
# take their block.
qemu_session_claim_block() {
    local session="$1" base="${2-}" live="${3-}"
    local dir registry lock tmp block line used name kept pruned
    local running unleased idle_block idle_name

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
        kept=""
        pruned=0
        block=""
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
            name="${line#* }"
            if [ -n "$base" ] && [ "$name" != "$session" ]; then
                case "$name" in
                    "$base-wt-"*)
                        case " $live " in
                            *" ${name#"$base-wt-"} "*) ;;
                            *)
                                pruned=1
                                rm -f "$dir/leases/$name"
                                continue
                                ;;
                        esac
                        ;;
                esac
            fi
            kept="$kept$line
"
            if [ "$name" = "$session" ]; then
                block="${line%% *}"
            fi
            used="$used ${line%% *}"
        done <"$registry"

        if [ "$pruned" -eq 1 ]; then
            tmp="$registry.tmp.$$"
            printf '%s' "$kept" >"$tmp"
            mv "$tmp" "$registry"
        fi
        if [ -n "$block" ]; then
            printf '%s\n' "$block"
            exit 0
        fi

        block=0
        while [ "$block" -lt "$QEMU_SESSION_PORT_BLOCKS" ]; do
            case " $used " in
                *" $block "*) block=$((block + 1)) ;;
                *) break ;;
            esac
        done
        if [ "$block" -ge "$QEMU_SESSION_PORT_BLOCKS" ]; then
            # Every number is taken: look for one nobody is using. A runner
            # takes its lease before it waits for this lock, so a free lease
            # here means that session's next claim comes after this one and
            # simply gets a block of its own.
            running=""
            unleased=""
            idle_block=""
            idle_name=""
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                name="${line#* }"
                if [ ! -e "$dir/leases/$name" ]; then
                    unleased="$unleased $name"
                elif ( exec 7>"$dir/leases/$name" && flock -n -x 7 ); then
                    idle_block="${line%% *}"
                    idle_name="$name"
                    break
                else
                    running="$running $name"
                fi
            done <<<"$kept"
            if [ -z "$idle_block" ]; then
                echo "FAIL qemu-session-ports: all $QEMU_SESSION_PORT_BLOCKS port" \
                     "blocks are claimed in $registry." \
                     "Running a lane:${running:- none}." \
                     "Written before leases, so possibly running, removed by" \
                     "scripts/prune_worktrees.py or a release:${unleased:- none}." >&2
                exit 1
            fi
            block="$idle_block"
            tmp="$registry.tmp.$$"
            awk -v name="$idle_name" \
                '{ line = $0; sub(/^[^ ]* /, "", line) } line != name' \
                "$registry" >"$tmp"
            mv "$tmp" "$registry"
            if [ "${TAKIBI_QEMU_PORT_VERBOSE:-0}" = 1 ]; then
                echo "[qemu-session-ports] $session took block $block from" \
                     "idle session $idle_name" >&2
            fi
        fi

        tmp="$registry.tmp.$$"
        cat "$registry" >"$tmp"
        printf '%s %s\n' "$block" "$session" >>"$tmp"
        mv "$tmp" "$registry"
        printf '%s\n' "$block"
    )
}

# The session name the port block is claimed under. TAKIBI_SESSION names the
# container (.devcontainer/devcontainer.json), so every git worktree inside it
# would share one name and therefore one block, and two worktree agents
# running lanes at once would bind the same ports (GitHub issue #753). A linked
# worktree therefore claims under the container's name plus its own directory
# name. Derived here rather than exported by whoever starts the agent, so a
# worktree cannot collide because somebody forgot to set it.
# QEMU_SESSION_REPO_ROOT exists for scripts/slowcheck_qemu_session_ports.sh.
qemu_session_name() {
    local base="${TAKIBI_SESSION:-}" root git_dir common_dir
    [ -n "$base" ] || return 0
    root="${QEMU_SESSION_REPO_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    git_dir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)" || git_dir=
    common_dir="$(cd "$root" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || common_dir=
    if [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$(cd "$git_dir" && pwd -P)" != "$common_dir" ]; then
        root="$(git -C "$root" rev-parse --show-toplevel)"
        base="$base-wt-$(basename "$root" | tr -c 'A-Za-z0-9._\n-' '_')"
    fi
    printf '%s\n' "$base"
}

# The names, as qemu_session_name spells them, of this repository's linked
# worktrees that exist now. Empty outside a git checkout, which prunes
# nothing: a row is dropped only when this repository can say it is gone.
qemu_session_live_worktrees() {
    local root path
    root="${QEMU_SESSION_REPO_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
    git -C "$root" worktree list --porcelain 2>/dev/null |
        sed -n 's/^worktree //p' |
        while IFS= read -r path; do
            [ -d "$path" ] || continue
            basename "$path" | tr -c 'A-Za-z0-9._\n-' '_'
        done | tr '\n' ' '
}

# Release a session's block, for the coordinator after it removes a worktree
# (GitHub issue #753): worktree sessions are short-lived and would otherwise
# fill the registry. Releasing a name that holds no block is not an error.
qemu_session_release_block() {
    local session="$1" dir registry
    dir="$(qemu_session_registry_dir)"
    registry="$dir/blocks"
    [ -e "$registry" ] || return 0
    (
        exec 8>"$dir/lock" || exit 1
        flock 8
        awk -v name="$session" '{ line = $0; sub(/^[^ ]* /, "", line) } line != name' \
            "$registry" >"$registry.tmp.$$"
        mv "$registry.tmp.$$" "$registry"
        rm -f "$dir/leases/$session"
    )
}

# Hold this session's lease for the rest of the calling shell and its children.
# It must run in the runner's own shell, not a command substitution, and before
# the claim: with the lease held first, a claim that sees it free has already
# finished with the registry by the time this session reads it, so no order
# leaves a running lane on a block someone else was just given. The descriptor
# is deliberately inherited, so a QEMU that outlives its runner keeps its block.
QEMU_SESSION_LEASE_FD=""
qemu_session_take_lease() {
    local session dir
    [ -z "$QEMU_SESSION_LEASE_FD" ] || return 0
    [ -z "${TAKIBI_QEMU_PORT_OFFSET:-}" ] || return 0
    session="$(qemu_session_name)"
    dir="$(qemu_session_registry_dir)"
    [ -n "$session" ] && [ -d "$dir" ] || return 0
    qemu_session_check_name "$session" || return 1
    mkdir -p "$dir/leases" || return 1
    exec {QEMU_SESSION_LEASE_FD}>"$dir/leases/$session" || return 1
    flock -s "$QEMU_SESSION_LEASE_FD"
}

qemu_session_check_name() {
    case "$1" in
        *[!A-Za-z0-9._-]*)
            echo "FAIL qemu-session-ports: the session name may contain only" \
                 "letters, digits, dot, underscore and dash: '$1'" >&2
            return 1
            ;;
    esac
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

    session="$(qemu_session_name)"
    if [ -z "$session" ] || [ ! -d "$(qemu_session_registry_dir)" ]; then
        printf '0\n'
        return 0
    fi
    qemu_session_check_name "$session" || return 1

    block="$(qemu_session_claim_block "$session" "${TAKIBI_SESSION:-}" \
        "$(qemu_session_live_worktrees)")" || return 1
    printf '%s\n' "$((block * QEMU_SESSION_PORT_STRIDE))"
}

# Shift the named port variables in place. One call per lane, naming exactly
# the ports that lane claims, so the lane's port set is written down once.
qemu_session_shift_ports() {
    local offset name current

    qemu_session_take_lease || exit 1
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
        echo "[qemu-session-ports] $(qemu_session_name) offset=+$offset" >&2
    fi
}
