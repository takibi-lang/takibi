#!/usr/bin/env bash
# Exclusive use of a physical board, across every container working on this
# repository. Sourced by a hardware runner, which then calls
# hardware_lease_acquire with the board name.
#
# The runners' existing locks do not cover this. The maintained kernel lane
# locks its artifact directory, which lives inside the clone, and the STM32
# claim locks a path under /tmp, which is per container. Two clones therefore
# passed both and drove one board at the same time; only a person deciding who
# went next prevented it.
#
# The lease is one flock in the registry every container mounts at the same
# path, so it excludes across containers. It is held by the runner's own open
# file description, so the kernel releases it when the runner exits for any
# reason -- finished, failed, interrupted, or killed. Nothing has to be given
# back, and a stopped agent releases its board immediately.
#
# A child that inherits the descriptor holds the lease too, and that is
# deliberate: if a runner is killed while its openocd or its serial reader
# survives, something is still driving the board, and handing it to another
# session then would be worse than making that session wait. Interrupting a
# runner from a terminal signals the whole process group, so the ordinary case
# releases everything at once. An orphan that outlives its runner shows up in
# hardware_lease_status as a board still held while its recorded holder is
# gone, which is the signal to look for the leftover process.
#
# The grain is one runner, deliberately, rather than an aggregate target. A
# lane resets the board and loads its own image before it tests anything, so
# another session's lane in between changes nothing for the next one. Short
# holds are what keeps a long measurement from monopolising the board: twenty
# samples of one lane become twenty short holds other sessions can interleave
# with, rather than one hour nobody else can use.
#
# There is no priority and no queue: everyone waits their turn, including the
# person. Inside a container a person and an agent share one TAKIBI_SESSION,
# so the lease could not tell them apart without a flag somebody has to
# remember. When a person needs the board now, stopping the agent sessions
# releases every lease they hold.
#
# Availability is not declared anywhere. The boards are physically
# disconnected when they are not in use, and each runner already refuses with
# a message naming the missing device.

HARDWARE_LEASE_TIMEOUT_SECONDS="${TAKIBI_HARDWARE_LEASE_TIMEOUT:-2700}"
HARDWARE_LEASE_FD=7
# Reported, never enforced. A board that stops answering SWD needs a power
# cycle, which no software here can perform, and a run whose TEST fails is not
# that. Refusing on a count would stop exactly the debugging session that
# legitimately produces many red hardware runs, so this counts and says so,
# and a rule can follow once the numbers exist.
HARDWARE_LEASE_STUCK_HINT=2

hardware_lease_dir() {
    printf '%s\n' "${TAKIBI_SESSION_REGISTRY:-$HOME/.takibi-sessions}/hardware"
}

hardware_lease_field() {
    # hardware_lease_field FILE KEY -- empty when absent.
    [ -f "$1" ] || return 0
    awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

hardware_lease_write() {
    # hardware_lease_write FILE KEY=VALUE... -- replaced whole, never appended,
    # so a reader sees one complete record or the previous one.
    local file="$1" tmp
    shift
    tmp="$file.tmp.$$"
    printf '%s\n' "$@" >"$tmp"
    mv "$tmp" "$file"
}

# A recorded pid means something only to the session that recorded it: each
# container has its own pid namespace, so another container's pid either names
# nothing here or names an unrelated local process. Ask about liveness only
# for a holder from this session, and otherwise report what was recorded
# without claiming anything about it. Whether the board is actually held is a
# question for the lock, which is namespace-independent.
hardware_lease_holder_line() {
    local file="$1" session target pid started
    session="$(hardware_lease_field "$file" session)"
    target="$(hardware_lease_field "$file" target)"
    pid="$(hardware_lease_field "$file" pid)"
    started="$(hardware_lease_field "$file" started)"
    if [ -z "$session" ]; then
        printf 'no holder recorded\n'
        return 0
    fi
    if [ "$session" = "${TAKIBI_SESSION:-}" ] && [ -n "$pid" ] \
            && ! kill -0 "$pid" 2>/dev/null; then
        printf '%s running %s since %s (pid %s, no longer running)\n' \
            "$session" "${target:-unknown}" "${started:-unknown}" "$pid"
        return 0
    fi
    printf '%s running %s since %s (pid %s)\n' \
        "$session" "${target:-unknown}" "${started:-unknown}" "$pid"
}

hardware_lease_acquire() {
    local board="$1" target="${2:-${MAKECMDGOALS:-$0}}"
    local dir lock holder runs failures today previous_day

    dir="$(hardware_lease_dir)"
    lock="$dir/$board.lock"
    holder="$dir/$board.holder"

    # An outer runner may already own this board. Trust the marker only when
    # the descriptor it names is really this board's lock, so exporting the
    # variable cannot borrow a lease nobody holds.
    if [ "${TAKIBI_HARDWARE_LEASE_HELD:-}" = "$board" ]; then
        local inherited expected
        inherited="$(readlink -f "/proc/$$/fd/$HARDWARE_LEASE_FD" 2>/dev/null || true)"
        expected="$(readlink -f "$lock" 2>/dev/null || true)"
        if [ -n "$inherited" ] && [ "$inherited" = "$expected" ]; then
            return 0
        fi
        echo "error: TAKIBI_HARDWARE_LEASE_HELD claims $board without its lock" >&2
        return 1
    fi

    mkdir -p "$dir"
    eval "exec $HARDWARE_LEASE_FD>\"\$lock\""
    if ! flock -n "$HARDWARE_LEASE_FD"; then
        echo "[hardware] waiting for $board: $(hardware_lease_holder_line "$holder")" >&2
        if ! flock -w "$HARDWARE_LEASE_TIMEOUT_SECONDS" "$HARDWARE_LEASE_FD"; then
            echo "FAIL hardware-lease: $board was still held after" \
                 "${HARDWARE_LEASE_TIMEOUT_SECONDS}s by" \
                 "$(hardware_lease_holder_line "$holder")" >&2
            return 1
        fi
    fi

    today="$(date +%Y-%m-%d)"
    previous_day="$(hardware_lease_field "$holder" day)"
    runs="$(hardware_lease_field "$holder" runs)"
    failures="$(hardware_lease_field "$holder" board_failures)"
    case "$runs" in ''|*[!0-9]*) runs=0;; esac
    case "$failures" in ''|*[!0-9]*) failures=0;; esac
    if [ "$previous_day" != "$today" ]; then
        runs=0
    fi

    if [ "$failures" -ge "$HARDWARE_LEASE_STUCK_HINT" ]; then
        echo "[hardware] $board has failed to reset or load $failures times in a" \
             "row. It may need a power cycle; this run is not being refused." >&2
    fi

    hardware_lease_write "$holder" \
        "board=$board" \
        "session=${TAKIBI_SESSION:-unknown}" \
        "target=$target" \
        "pid=$$" \
        "started=$(date +%H:%M:%S)" \
        "day=$today" \
        "runs=$((runs + 1))" \
        "board_failures=$failures"

    export TAKIBI_HARDWARE_LEASE_HELD="$board"
}

# Record whether the BOARD answered, as distinct from whether the tests passed.
# Only a reset or load failure means the board itself stopped responding.
hardware_lease_board_failed() {
    local holder failures
    holder="$(hardware_lease_dir)/${TAKIBI_HARDWARE_LEASE_HELD:-none}.holder"
    [ -f "$holder" ] || return 0
    failures="$(hardware_lease_field "$holder" board_failures)"
    case "$failures" in ''|*[!0-9]*) failures=0;; esac
    hardware_lease_write "$holder" \
        "board=$(hardware_lease_field "$holder" board)" \
        "session=$(hardware_lease_field "$holder" session)" \
        "target=$(hardware_lease_field "$holder" target)" \
        "pid=$(hardware_lease_field "$holder" pid)" \
        "started=$(hardware_lease_field "$holder" started)" \
        "day=$(hardware_lease_field "$holder" day)" \
        "runs=$(hardware_lease_field "$holder" runs)" \
        "board_failures=$((failures + 1))"
}

hardware_lease_board_ok() {
    local holder
    holder="$(hardware_lease_dir)/${TAKIBI_HARDWARE_LEASE_HELD:-none}.holder"
    [ -f "$holder" ] || return 0
    [ "$(hardware_lease_field "$holder" board_failures)" = 0 ] && return 0
    hardware_lease_write "$holder" \
        "board=$(hardware_lease_field "$holder" board)" \
        "session=$(hardware_lease_field "$holder" session)" \
        "target=$(hardware_lease_field "$holder" target)" \
        "pid=$(hardware_lease_field "$holder" pid)" \
        "started=$(hardware_lease_field "$holder" started)" \
        "day=$(hardware_lease_field "$holder" day)" \
        "runs=$(hardware_lease_field "$holder" runs)" \
        "board_failures=0"
}

# Who has which board, for a person who wants to know before waiting.
hardware_lease_status() {
    local dir holder board lock state recorded
    dir="$(hardware_lease_dir)"
    if [ ! -d "$dir" ]; then
        echo "no hardware lease registry at $dir"
        return 0
    fi
    shopt -s nullglob
    for holder in "$dir"/*.holder; do
        board="$(basename "$holder" .holder)"
        lock="$dir/$board.lock"
        recorded="$(hardware_lease_holder_line "$holder")"
        # The lock is the authority on whether the board is taken, because it
        # is the one fact that crosses containers. The record only says who
        # took it last.
        if (exec 6>"$lock" && flock -n 6) 2>/dev/null; then
            state="free"
        elif [ "$(hardware_lease_field "$holder" session)" = "${TAKIBI_SESSION:-}" ] \
                && ! kill -0 "$(hardware_lease_field "$holder" pid)" 2>/dev/null; then
            state="HELD by a process outliving its runner -- look for a leftover"
        else
            state="held"
        fi
        printf '%-8s %s: %s\n' "$board" "$state" "$recorded"
        printf '%-8s   runs today: %s, consecutive board failures: %s\n' "" \
            "$(hardware_lease_field "$holder" runs)" \
            "$(hardware_lease_field "$holder" board_failures)"
    done
    shopt -u nullglob
}
