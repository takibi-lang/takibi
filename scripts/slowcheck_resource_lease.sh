#!/usr/bin/env bash
# Regression controls for cross-container board and aggregate-suite leases.
#
# Every case uses a fictitious board and a command that touches nothing, so
# this runs anywhere and never drives real hardware.
set -euo pipefail
# The planted vCPU waits below (lane-a, lane-b, ...) are not the run's own:
# without this they land in the enclosing allcheck's lease-wait summary (#914).
unset TAKIBI_LANE_TIMING_DIR TAKIBI_AWAIT_TIMING_LANE

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/scripts/resource_lease.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -r "$tmp_dir"' EXIT
registry="$tmp_dir/registry"
mkdir -p "$registry"
holder="$registry/leases/testboard.holder"

# GitHub issue #526: a control asserts the number of claims it made. A PASS
# that names zero of them is a run that checked nothing, which is the same
# silence scripts/pass_line.py refuses on the Python side.
cases=0
claim() { cases=$((cases + 1)); }

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
    && claim || fail "a free board could not be acquired"
[ "$(field session)" = agent-a ] && claim || fail "the holder's session was not recorded"
[ "$(field target)" = "make kernelcheck-rpi5" ] \
    && claim || fail "the holder's target was not recorded"
[ "$(field runs)" = 1 ] && claim || fail "the first run was not counted"

# A second session waits rather than driving the same board, and says who has
# it. The wait is bounded so a stuck holder cannot hang a lane forever.
# `exec` so the process that holds the lease is the one this test kills, which
# is the ordinary case: a runner holds its own lease.
env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-a \
    bash -c ". '$helper'; resource_lease_acquire testboard slow && : >'$tmp_dir/first.held'; exec sleep 30" &
first=$!
# Ask only once the first holds the board: a fixed sleep let a loaded host
# hand it to the second instead (GitHub issue #928, the shape of #785).
for _ in $(seq 1 300); do
    [ -e "$tmp_dir/first.held" ] && break
    sleep 0.1
done
[ -e "$tmp_dir/first.held" ] || fail "the first session did not take testboard within 30 s"
if env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-b \
        TAKIBI_RESOURCE_LEASE_TIMEOUT=1 \
        bash -c ". '$helper'; resource_lease_acquire testboard second" \
        >"$tmp_dir/wait.log" 2>&1; then
    fail "a held board was handed to a second session"
fi
grep -F "waiting for testboard" "$tmp_dir/wait.log" >/dev/null \
    && claim || fail "waiting did not name the board"
grep -F "agent-a running slow" "$tmp_dir/wait.log" >/dev/null \
    && claim || fail "waiting did not name the holder"

# The holder is a process, not a flag: killing it releases the board at once,
# which is what makes an interrupted run and a stopped agent safe.
kill -KILL "$first" 2>/dev/null || true
wait "$first" 2>/dev/null || true
timeout 5 env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-c \
    bash -c ". '$helper'; resource_lease_acquire testboard third" >/dev/null \
    && claim || fail "a killed holder left the board locked"

# An outer runner's lease is reused, and only when its descriptor really is
# this board's lock; the marker alone must not borrow one.
lease agent-a 'resource_lease_acquire testboard outer
    bash -c ". '"'$helper'"'; resource_lease_acquire testboard inner"' \
    && claim || fail "a nested acquire did not reuse the outer lease"
if env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-a \
        TAKIBI_RESOURCE_LEASE_HELD=testboard \
        bash -c ". '$helper'; resource_lease_acquire testboard forged" \
        >"$tmp_dir/forged.log" 2>&1; then
    fail "an environment marker borrowed a lease nobody held"
fi
grep -F "without its lock" "$tmp_dir/forged.log" >/dev/null \
    && claim || fail "the forged-marker message does not say what was wrong"

# A board that stops answering is counted and reported, and a run that answers
# clears it. This is deliberately a report and not a refusal: a debugging
# session legitimately produces many red hardware runs, and refusing on a count
# would stop exactly that work.
for _attempt in 1 2; do
    lease agent-a 'resource_lease_acquire testboard run >/dev/null
        resource_lease_board_failed'
done
[ "$(field board_failures)" = 2 ] && claim || fail "board failures were not counted"
lease agent-a 'resource_lease_acquire testboard run' >"$tmp_dir/hint.log" 2>&1 \
    && claim || fail "a board with failures behind it was refused"
grep -F "may need a power cycle" "$tmp_dir/hint.log" >/dev/null \
    && claim || fail "repeated board failures were not reported"
lease agent-a 'resource_lease_acquire testboard run >/dev/null
    resource_lease_board_ok' 2>/dev/null
[ "$(field board_failures)" = 0 ] && claim || fail "a board that answered did not clear"

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
    && claim || fail "the orphan control did not leave a process behind"
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
# Bounded only on the child starting (GitHub issue #928): 0.5 s was too short
# for a loaded host.
for _attempt in $(seq 1 300); do
    [ -s "$tmp_dir/suite-child.pid" ] && break
    sleep 0.1
done
suite_child="$(cat "$tmp_dir/suite-child.pid" 2>/dev/null || true)"
[ -n "$suite_child" ] && kill -0 "$suite_child" 2>/dev/null \
    && claim || fail "the suite child did not start"
kill -KILL "$suite_runner" 2>/dev/null || true
wait "$suite_runner" 2>/dev/null || true
kill -0 "$suite_child" 2>/dev/null \
    && claim || fail "the suite child did not outlive its runner"
timeout 2 env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-next \
    bash -c ". '$helper'; resource_lease_acquire suite next" >/dev/null \
    || {
        kill -KILL "$suite_child" 2>/dev/null || true
        fail "an orphaned suite child retained the lease"
    }
kill -KILL "$suite_child" 2>/dev/null || true

# GitHub issue #719: QEMU guests lease vCPUs from a host-wide budget. With a
# budget of 4 and 3 held, a guest of 2 waits rather than oversubscribing,
# while a guest of 1 still fits.
vcpu() {
    # vcpu SESSION TIMEOUT SCRIPT -- run SCRIPT with a budget of 4 vCPUs.
    local session="$1" wait="$2"
    shift 2
    env -u TAKIBI_RESOURCE_LEASE_HELD TAKIBI_QEMU_VCPU_BUDGET=4 \
        TAKIBI_RESOURCE_LEASE_TIMEOUT="$wait" \
        TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION="$session" \
        bash -c ". '$repo_root/scripts/vcpu_lease.sh'; $*"
}
# lane-a marks the moment it holds its 3, and lane-b asks only after that:
# on a loaded host a fixed sleep let lane-b ask first and win (GitHub issue
# #785). The bound applies to lane-a getting started, not to the control.
vcpu lane-a 5 "resource_lease_vcpu_acquire 3 lane-a && : > '$tmp_dir/lane-a.held'; exec sleep 30" 2>/dev/null &
vcpu_a=$!
for _ in $(seq 1 300); do
    [ -e "$tmp_dir/lane-a.held" ] && break
    sleep 0.1
done
[ -e "$tmp_dir/lane-a.held" ] || fail "lane-a did not acquire 3 of 4 vCPUs within 30 s"
if vcpu lane-b 1 'resource_lease_vcpu_acquire 2 lane-b' >"$tmp_dir/vcpu-wait.log" 2>&1; then
    pkill -KILL -P "$vcpu_a" 2>/dev/null || true
    fail "a guest of 2 vCPUs started while 3 of a budget of 4 were held"
fi
grep -F "waiting for 1 more of 2 vCPUs (budget 4): lane-a lane-a x3" \
    "$tmp_dir/vcpu-wait.log" >/dev/null \
    && claim || fail "the vCPU wait did not say who holds the budget: $(cat "$tmp_dir/vcpu-wait.log")"
vcpu lane-c 1 'resource_lease_vcpu_acquire 1 lane-c' \
    && claim || fail "a guest of 1 vCPU did not fit beside 3 of 4"

# Two waiters that each need 3 must not deadlock on partial holds: the
# allocator lets one gather all of its slots before the other takes any.
vcpu lane-d 10 'resource_lease_vcpu_acquire 3 lane-d; exec sleep 1' 2>/dev/null &
vcpu_d=$!
sleep 0.3
vcpu lane-e 10 'resource_lease_vcpu_acquire 3 lane-e' 2>/dev/null &
vcpu_e=$!
sleep 0.3
# $! is the subshell running the function; the lease is held by its child.
pkill -KILL -P "$vcpu_a" 2>/dev/null || true
wait "$vcpu_a" 2>/dev/null || true
wait "$vcpu_d" && wait "$vcpu_e" \
    && claim || fail "two waiters for 3 of 4 vCPUs did not both run in turn"

# The QEMU shim refuses a guest larger than its runner's lease, including a
# runner whose Python subprocess closed the inherited descriptors.
mkdir -p "$tmp_dir/bin"
printf '#!/bin/sh\necho fake-qemu-started\n' >"$tmp_dir/bin/qemu-system-aarch64"
chmod +x "$tmp_dir/bin/qemu-system-aarch64"
shim="$repo_root/scripts/qemu.sh"
if PATH="$tmp_dir/bin:$PATH" vcpu lane-f 1 "'$shim' -smp 2" >/dev/null 2>&1; then
    fail "the QEMU shim started a guest without a vCPU lease"
fi
claim
PATH="$tmp_dir/bin:$PATH" vcpu lane-g 1 "resource_lease_vcpu_acquire 2 lane-g; \
    python3 -c 'import subprocess, sys; subprocess.run([sys.argv[1], \"-smp\", \"2\"], check=True)' '$shim'" \
    | grep -qx fake-qemu-started \
    && claim || fail "the QEMU shim refused a guest its Python runner had leased"

# allcheck's recipe sources resource_lease.sh with /bin/sh, so one bash-only
# construct in it stops allcheck before it starts. That happened when the vCPU
# budget was first added to this file; it now lives in vcpu_lease.sh.
if command -v dash >/dev/null; then
    dash -n "$helper" && claim || fail "resource_lease.sh no longer parses under dash"
fi

# Status is readable by a person deciding whether to wait.
status="$(env -u TAKIBI_RESOURCE_LEASE_HELD \
    TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=agent-a bash -c \
    ". '$helper'; resource_lease_status")"
case "$status" in
    *testboard*) ;;
    *) fail "status does not mention the board" ;;
esac

echo "PASS resource-lease: $cases claims -- boards are exclusive across clones, released by a" \
     "dying holder, kept by one that outlives its runner, reused when nested;" \
     "suite children do not inherit; board failures remain reported;" \
     "QEMU guests wait for vCPUs within the host budget"
