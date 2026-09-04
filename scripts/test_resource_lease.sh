#!/usr/bin/env bash
# Regression controls for cross-container board and aggregate-suite leases.
#
# Every case uses a fictitious board and a command that touches nothing, so
# this runs anywhere and never drives real hardware.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/scripts/resource_lease.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -r "$tmp_dir"' EXIT
registry="$tmp_dir/registry"
mkdir -p "$registry"
holder="$registry/leases/testboard.holder"

fail() {
    echo "FAIL resource-lease: $1" >&2
    exit 1
}

lease() {
    # lease SESSION SCRIPT -- run SCRIPT with the helper sourced.
    #
    # Every variable the lease reads is removed first, so a case sets only what
    # it means to. This runs inside a container that exports TAKIBI_SESSION,
    # and could run inside a runner that already holds a lease.
    local session="$1"
    shift
    env -u TAKIBI_RESOURCE_LEASE_HELD -u TAKIBI_RESOURCE_LEASE_TIMEOUT \
        TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION="$session" \
        bash -c ". '$helper'; $*"
}

field() {
    env TAKIBI_SESSION_REGISTRY="$registry" bash -c \
        ". '$helper'; resource_lease_field '$holder' '$1'"
}

# Acquiring records who holds the board, for what, and since when.
lease agent-a 'resource_lease_acquire testboard "make kernelcheck-rpi5"' \
    || fail "a free board could not be acquired"
[ "$(field session)" = agent-a ] || fail "the holder's session was not recorded"
[ "$(field target)" = "make kernelcheck-rpi5" ] \
    || fail "the holder's target was not recorded"
[ "$(field runs)" = 1 ] || fail "the first run was not counted"

# A second session waits rather than driving the same board, and says who has
# it. The wait is bounded so a stuck holder cannot hang a lane forever.
# `exec` so the process that holds the lease is the one this test kills, which
# is the ordinary case: a runner holds its own lease.
env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-a \
    bash -c ". '$helper'; resource_lease_acquire testboard slow; exec sleep 30" &
first=$!
sleep 0.5
if env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-b \
        TAKIBI_RESOURCE_LEASE_TIMEOUT=1 \
        bash -c ". '$helper'; resource_lease_acquire testboard second" \
        >"$tmp_dir/wait.log" 2>&1; then
    fail "a held board was handed to a second session"
fi
grep -F "waiting for testboard" "$tmp_dir/wait.log" >/dev/null \
    || fail "waiting did not name the board"
grep -F "agent-a running slow" "$tmp_dir/wait.log" >/dev/null \
    || fail "waiting did not name the holder"

# The holder is a process, not a flag: killing it releases the board at once,
# which is what makes an interrupted run and a stopped agent safe.
kill -KILL "$first" 2>/dev/null || true
wait "$first" 2>/dev/null || true
timeout 5 env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-c \
    bash -c ". '$helper'; resource_lease_acquire testboard third" >/dev/null \
    || fail "a killed holder left the board locked"

# An outer runner's lease is reused, and only when its descriptor really is
# this board's lock; the marker alone must not borrow one.
lease agent-a 'resource_lease_acquire testboard outer
    bash -c ". '"'$helper'"'; resource_lease_acquire testboard inner"' \
    || fail "a nested acquire did not reuse the outer lease"
if env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-a \
        TAKIBI_RESOURCE_LEASE_HELD=testboard \
        bash -c ". '$helper'; resource_lease_acquire testboard forged" \
        >"$tmp_dir/forged.log" 2>&1; then
    fail "an environment marker borrowed a lease nobody held"
fi
grep -F "without its lock" "$tmp_dir/forged.log" >/dev/null \
    || fail "the forged-marker message does not say what was wrong"

# A board that stops answering is counted and reported, and a run that answers
# clears it. This is deliberately a report and not a refusal: a debugging
# session legitimately produces many red hardware runs, and refusing on a count
# would stop exactly that work.
for _attempt in 1 2; do
    lease agent-a 'resource_lease_acquire testboard run >/dev/null
        resource_lease_board_failed'
done
[ "$(field board_failures)" = 2 ] || fail "board failures were not counted"
lease agent-a 'resource_lease_acquire testboard run' >"$tmp_dir/hint.log" 2>&1 \
    || fail "a board with failures behind it was refused"
grep -F "may need a power cycle" "$tmp_dir/hint.log" >/dev/null \
    || fail "repeated board failures were not reported"
lease agent-a 'resource_lease_acquire testboard run >/dev/null
    resource_lease_board_ok' 2>/dev/null
[ "$(field board_failures)" = 0 ] || fail "a board that answered did not clear"

# A child that outlives its runner keeps the lease, because something may still
# be driving the board. The board then reads as held while its recorded holder
# is gone, which is how a leftover process is noticed rather than silently
# handing the board to the next session.
lease agent-a "resource_lease_acquire testboard orphaned >/dev/null
    sleep 30 &
    echo \$! >'$tmp_dir/orphan.pid'
    exit 0" 2>/dev/null
orphan="$(cat "$tmp_dir/orphan.pid" 2>/dev/null || true)"
[ -n "$orphan" ] && kill -0 "$orphan" 2>/dev/null \
    || fail "the orphan control did not leave a process behind"
if timeout 2 env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-d \
        TAKIBI_RESOURCE_LEASE_TIMEOUT=1 \
        bash -c ". '$helper'; resource_lease_acquire testboard next" \
        >/dev/null 2>&1; then
    kill -KILL "$orphan" 2>/dev/null || true
    fail "a board still held by a leftover process was handed on"
fi
# Asked from the session whose runner died: a recorded pid means nothing to any
# other container, so only its own session can recognise a leftover.
orphan_status="$(env -u TAKIBI_RESOURCE_LEASE_HELD \
    TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-a bash -c \
    ". '$helper'; resource_lease_status")"
kill -KILL "$orphan" 2>/dev/null || true
case "$orphan_status" in
    *"outliving its runner"*) ;;
    *) fail "status did not report the leftover holder: $orphan_status" ;;
esac

# A holder recorded by another container is reported without any claim about
# its pid, which names nothing in this pid namespace.
foreign="$(env -u TAKIBI_RESOURCE_LEASE_HELD \
    TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=someone-else bash -c \
    ". '$helper'; resource_lease_holder_line '$holder'")"
case "$foreign" in
    *"no longer running"*) fail "another container's pid was judged for liveness" ;;
    *agent-a*) ;;
    *) fail "a foreign holder was not reported: $foreign" ;;
esac

# Unlike a board child, an aggregate child must not retain the suite lease
# after its runner dies. It may keep doing harmless build work, but another
# clone must not wait for an aggregate that no longer exists.
env -u TAKIBI_RESOURCE_LEASE_HELD \
    TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-suite \
    bash -c ". '$helper'; resource_lease_run_suite allcheck \
        bash -c 'echo \$\$ >\"$tmp_dir/suite-child.pid\"; exec sleep 30'" &
suite_runner=$!
for _attempt in 1 2 3 4 5; do
    [ -s "$tmp_dir/suite-child.pid" ] && break
    sleep 0.1
done
suite_child="$(cat "$tmp_dir/suite-child.pid" 2>/dev/null || true)"
[ -n "$suite_child" ] && kill -0 "$suite_child" 2>/dev/null \
    || fail "the suite child did not start"
kill -KILL "$suite_runner" 2>/dev/null || true
wait "$suite_runner" 2>/dev/null || true
kill -0 "$suite_child" 2>/dev/null \
    || fail "the suite child did not outlive its runner"
timeout 2 env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-next \
    bash -c ". '$helper'; resource_lease_acquire suite next" >/dev/null \
    || {
        kill -KILL "$suite_child" 2>/dev/null || true
        fail "an orphaned suite child retained the lease"
    }
kill -KILL "$suite_child" 2>/dev/null || true

# Status is readable by a person deciding whether to wait.
status="$(env -u TAKIBI_RESOURCE_LEASE_HELD \
    TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-a bash -c \
    ". '$helper'; resource_lease_status")"
case "$status" in
    *testboard*) ;;
    *) fail "status does not mention the board" ;;
esac

echo "PASS resource-lease: boards are exclusive across clones, released by a" \
     "dying holder, kept by one that outlives its runner, reused when nested;" \
     "suite children do not inherit; board failures remain reported"
