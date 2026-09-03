#!/usr/bin/env bash
# Exclusive use of one shared resource, across every container working on this
# repository. Sourced by a runner, which then calls resource_lease_acquire with
# the resource's name. Three exist: `rpi5`, `stm32`, and `suite`.
#
# The runners' existing locks do not cover this. The maintained kernel lane
# locks its artifact directory, which lives inside the clone, and the STM32
# claim locks a path under /tmp, which is per container. Two clones therefore
# passed both and drove one board at the same time; only a person deciding who
# went next prevented it.
#
# `suite` is the machine, not a device. Measured on a 24-core host: twelve
# concurrent QEMU lanes all passed in 29s against a 90s budget, while three
# concurrent aggregates -- each adding a compiler build and the unit suite on
# top of eight lanes -- starved the host enough that the guest stopped making
# progress mid-boot, always at the same line. So the lane is not the unit that
# needs limiting and the aggregate is: `make kernelcheck` and `make allcheck`
# take this lease, individual lanes take nothing, and parallel work on separate
# lanes keeps running at full speed.
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
# resource_lease_status as a board still held while its recorded holder is
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

RESOURCE_LEASE_TIMEOUT_SECONDS="${TAKIBI_RESOURCE_LEASE_TIMEOUT:-2700}"
RESOURCE_LEASE_FD=7
# Reported, never enforced. A board that stops answering SWD needs a power
# cycle, which no software here can perform, and a run whose TEST fails is not
# that. Refusing on a count would stop exactly the debugging session that
# legitimately produces many red hardware runs, so this counts and says so,
# and a rule can follow once the numbers exist.
RESOURCE_LEASE_STUCK_HINT=2

resource_lease_dir() {
    printf '%s\n' "${TAKIBI_SESSION_REGISTRY:-$HOME/.takibi-sessions}/leases"
}

resource_lease_field() {
    # resource_lease_field FILE KEY -- empty when absent.
    [ -f "$1" ] || return 0
    awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

resource_lease_write() {
    # resource_lease_write FILE KEY=VALUE... -- replaced whole, never appended,
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
resource_lease_holder_line() {
    local file="$1" session target pid started
    session="$(resource_lease_field "$file" session)"
    target="$(resource_lease_field "$file" target)"
    pid="$(resource_lease_field "$file" pid)"
    started="$(resource_lease_field "$file" started)"
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

resource_lease_acquire() {
    local resource="$1" target="${2:-${MAKECMDGOALS:-$0}}"
    local dir lock holder runs failures today previous_day

    dir="$(resource_lease_dir)"
    lock="$dir/$resource.lock"
    holder="$dir/$resource.holder"

    # An outer runner may already own this resource. Trust the marker only
    # when the descriptor it names is really this resource's lock, so exporting
    # variable cannot borrow a lease nobody holds.
    if [ "${TAKIBI_RESOURCE_LEASE_HELD:-}" = "$resource" ]; then
        local inherited expected
        inherited="$(readlink -f "/proc/$$/fd/$RESOURCE_LEASE_FD" 2>/dev/null || true)"
        expected="$(readlink -f "$lock" 2>/dev/null || true)"
        if [ -n "$inherited" ] && [ "$inherited" = "$expected" ]; then
            return 0
        fi
        echo "error: TAKIBI_RESOURCE_LEASE_HELD claims $resource without its lock" >&2
        return 1
    fi

    mkdir -p "$dir"
    eval "exec $RESOURCE_LEASE_FD>\"\$lock\""
    if ! flock -n "$RESOURCE_LEASE_FD"; then
        echo "[lease] waiting for $resource: $(resource_lease_holder_line "$holder")" >&2
        if ! flock -w "$RESOURCE_LEASE_TIMEOUT_SECONDS" "$RESOURCE_LEASE_FD"; then
            echo "FAIL resource-lease: $resource was still held after" \
                 "${RESOURCE_LEASE_TIMEOUT_SECONDS}s by" \
                 "$(resource_lease_holder_line "$holder")" >&2
            return 1
        fi
    fi

    today="$(date +%Y-%m-%d)"
    previous_day="$(resource_lease_field "$holder" day)"
    runs="$(resource_lease_field "$holder" runs)"
    failures="$(resource_lease_field "$holder" board_failures)"
    case "$runs" in ''|*[!0-9]*) runs=0;; esac
    case "$failures" in ''|*[!0-9]*) failures=0;; esac
    if [ "$previous_day" != "$today" ]; then
        runs=0
    fi

    if [ "$failures" -ge "$RESOURCE_LEASE_STUCK_HINT" ]; then
        echo "[lease] $resource has failed to reset or load $failures times in a" \
             "row. It may need a power cycle; this run is not being refused." >&2
    fi

    resource_lease_write "$holder" \
        "resource=$resource" \
        "session=${TAKIBI_SESSION:-unknown}" \
        "target=$target" \
        "pid=$$" \
        "started=$(date +%H:%M:%S)" \
        "day=$today" \
        "runs=$((runs + 1))" \
        "board_failures=$failures"

    export TAKIBI_RESOURCE_LEASE_HELD="$resource"
}

# Record whether the BOARD answered, as distinct from whether the tests passed.
# Only a reset or load failure means the board itself stopped responding.
resource_lease_board_failed() {
    local holder failures
    holder="$(resource_lease_dir)/${TAKIBI_RESOURCE_LEASE_HELD:-none}.holder"
    [ -f "$holder" ] || return 0
    failures="$(resource_lease_field "$holder" board_failures)"
    case "$failures" in ''|*[!0-9]*) failures=0;; esac
    resource_lease_write "$holder" \
        "resource=$(resource_lease_field "$holder" resource)" \
        "session=$(resource_lease_field "$holder" session)" \
        "target=$(resource_lease_field "$holder" target)" \
        "pid=$(resource_lease_field "$holder" pid)" \
        "started=$(resource_lease_field "$holder" started)" \
        "day=$(resource_lease_field "$holder" day)" \
        "runs=$(resource_lease_field "$holder" runs)" \
        "board_failures=$((failures + 1))"
}

resource_lease_board_ok() {
    local holder
    holder="$(resource_lease_dir)/${TAKIBI_RESOURCE_LEASE_HELD:-none}.holder"
    [ -f "$holder" ] || return 0
    [ "$(resource_lease_field "$holder" board_failures)" = 0 ] && return 0
    resource_lease_write "$holder" \
        "resource=$(resource_lease_field "$holder" resource)" \
        "session=$(resource_lease_field "$holder" session)" \
        "target=$(resource_lease_field "$holder" target)" \
        "pid=$(resource_lease_field "$holder" pid)" \
        "started=$(resource_lease_field "$holder" started)" \
        "day=$(resource_lease_field "$holder" day)" \
        "runs=$(resource_lease_field "$holder" runs)" \
        "board_failures=0"
}

# Who has which board, for a person who wants to know before waiting.
resource_lease_status() {
    local dir holder resource lock state recorded
    dir="$(resource_lease_dir)"
    if [ ! -d "$dir" ]; then
        echo "no lease registry at $dir"
        return 0
    fi
    shopt -s nullglob
    for holder in "$dir"/*.holder; do
        resource="$(basename "$holder" .holder)"
        lock="$dir/$resource.lock"
        recorded="$(resource_lease_holder_line "$holder")"
        # The lock is the authority on whether it is taken, because it
        # is the one fact that crosses containers. The record only says who
        # took it last.
        if (exec 6>"$lock" && flock -n 6) 2>/dev/null; then
            state="free"
        elif [ "$(resource_lease_field "$holder" session)" = "${TAKIBI_SESSION:-}" ] \
                && ! kill -0 "$(resource_lease_field "$holder" pid)" 2>/dev/null; then
            state="HELD by a process outliving its runner -- look for a leftover"
        else
            state="held"
        fi
        printf '%-8s %s: %s\n' "$resource" "$state" "$recorded"
        printf '%-8s   runs today: %s, consecutive board failures: %s\n' "" \
            "$(resource_lease_field "$holder" runs)" \
            "$(resource_lease_field "$holder" board_failures)"
    done
    shopt -u nullglob
}
