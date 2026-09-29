#!/usr/bin/env bash
# Deterministic fail-stop regression: stop QEMU at reset, use GDB only to
# replace the first ordinary EL0 instruction with BRK #0, then verify both
# the UART oops record and retained structured CrashSnapshot while the kernel
# itself has parked the CPU. `child_exec` instead stops immediately after a
# real exec commit through a debugger-owned, default-false test switch, while
# `child_exec_prepare_failure` forces one named prepare result at its real
# call boundary through compiler-emitted variant-return metadata.
set -euo pipefail

# `set -e` aborts with no context, and a lane's setup prints nothing on
# success -- a CI failure once reported exit 74 and not one line saying
# which command produced it. Name the line, the command and the status.
trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="${KERNEL_QEMU_OOPS_ELF:-$REPO_ROOT/kernel/build/qemu/kernel-debug.elf}"
# shellcheck source=scripts/kernel_elf_freshness.sh
. "$REPO_ROOT/scripts/kernel_elf_freshness.sh"
kernel_elf_refuse_stale "$ELF" || exit 1
DEBUG_METADATA="$REPO_ROOT/_build/kernel-debug-metadata.json"
ARTIFACT_DIR="${KERNEL_QEMU_OOPS_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-oops-qemu}"
GDB_PORT="${KERNEL_QEMU_OOPS_GDB_PORT:-18697}"
SERIAL_PORT="${KERNEL_QEMU_OOPS_SERIAL_PORT:-18698}"
MODE="${KERNEL_QEMU_OOPS_MODE:-brk}"
UART_LOG="$ARTIFACT_DIR/uart.log"
SNAPSHOT_LAYOUT="$REPO_ROOT/_build/kernel-crash-snapshot-layout.gdb"
mkdir -p "$ARTIFACT_DIR"
# The root filesystem is the virtio disk; the kernel carries no copy of the
# image to fall back to.
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
cp "$REPO_ROOT/kernel/build/user/ext2.img" "$QEMU_EXT2_IMAGE"
: >"$UART_LOG"

# GitHub issue #407: see scripts/qemu_port_guard.py. Refuse to start if
# somebody already owns this lane's ports, and say that rather than
# reporting a kernel that was never asked anything.
. "$REPO_ROOT/scripts/qemu_session_ports.sh"
qemu_session_shift_ports GDB_PORT SERIAL_PORT
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "kernel/qemu oops" \
    "tcp:$GDB_PORT" "tcp:$SERIAL_PORT" || exit 1
if ! command -v gdb-multiarch >/dev/null 2>&1; then
    echo "error: gdb-multiarch is required for kernelcheck-oops-qemu" >&2
    exit 1
fi

case "$MODE" in
    brk)
        fault_instruction=0xd4200000
        expected_ec=3c
        expected_detail=''
        ;;
    data_abort_write)
        # str x0, [x0]: x0 holds argc at this entry, so this is an ordinary
        # EL0 write to an unmapped low address and must take a data abort.
        fault_instruction=0xf9000000
        expected_ec=24
        expected_detail='^oops: data-abort dfsc=0x000000000000000[0-9a-f] access=write$'
        ;;
    child_exec)
        fault_instruction=''
        expected_ec=15
        expected_detail=''
        ;;
    child_exec_prepare_failure)
        fault_instruction=''
        expected_ec=15
        expected_detail=''
        ;;
    peer_fault)
        # A fault on the peer. Its entry instruction is replaced before
        # anything executes, so core 1 fail-stops during bring-up, and its
        # report must stop core 0 before the console runs (#619).
        #
        # This mode used to be the two-core report of GitHub issue #486: core
        # 0 went on to its own EL0 BRK and both records were listed in fault
        # order. That rested on the peer's world stop never being
        # acknowledged -- GICC_IAR carries the sending CPU, and the dispatcher
        # recognised only core 0's stop SGI (#632). With that fixed, the
        # peer's report stops core 0 for good, as a fail-stop should, and
        # core 0 never faults. A scenario where two cores fault before either
        # can stop the other is concurrent_fault below.
        fault_instruction=0xd4200000
        expected_ec=3c
        expected_detail=''
        ;;
    concurrent_fault)
        # GitHub issue #634: two online cores fault before either can stop
        # the other -- the case the fault-order ticket, the report claim and
        # `abandoned=0` exist for, and the one peer_fault lost when #632 made
        # a peer's world stop work. Both faults are BRK #0: core 0's at its
        # first EL0 instruction, core 1's at EL1 in its idle loop. GDB holds
        # each inside the fail-stop path and releases them together.
        fault_instruction=0xd4200000
        expected_ec=3c
        expected_detail=''
        ;;
    *)
        echo "error: unknown KERNEL_QEMU_OOPS_MODE: $MODE" >&2
        exit 1
        ;;
esac

qemu-system-aarch64 -machine virt -cpu cortex-a53 -smp 2 -m 1024 \
    -display none -monitor none \
    -drive "file=$QEMU_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -serial "tcp:127.0.0.1:$SERIAL_PORT,server=on,wait=on" \
    -S -gdb "tcp::$GDB_PORT" -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
qemu_pid=$!
console_driver_pid=""
cleanup() {
    if [ -n "$console_driver_pid" ]; then
        kill "$console_driver_pid" 2>/dev/null || true
        wait "$console_driver_pid" 2>/dev/null || true
    fi
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
}
archive_on_failure() {
    local status="$1"
    if [ "$status" -ne 0 ]; then
        bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" "$ARTIFACT_DIR" \
            "$REPO_ROOT/_build/kernel-oops-qemu-failures" \
            "exit status $status (mode $MODE)" || true
    fi
}
cleanup_and_archive() {
    local status=$?
    cleanup
    archive_on_failure "$status"
    return "$status"
}
trap cleanup_and_archive EXIT
trap 'cleanup; exit 130' INT TERM HUP

console_await=()
if [ "$MODE" = peer_fault ]; then
    # This mode waits for a WHOLE BOOT, not just a crash console: the peer
    # fail-stops during bring-up and core 0 only reaches its own fault after
    # userspace starts. The default budget is sized for the latter alone, and
    # measured at 1-in-3 failures here before this was raised.
    console_await=(--timeout 90)
    console_await+=(--await-line "oops: fail-stop seq=1 cpu=1")
elif [ "$MODE" = concurrent_fault ]; then
    # A whole boot again: core 0's fault is PID 1's first instruction.
    # Both records before the first question: the console's first prompt
    # belongs to whichever core claimed it, and asking for `oops` before the
    # other has reported would answer about half the machine and pass.
    console_await=(--timeout 90)
    console_await+=(--await-line "oops: fail-stop seq=1 cpu=0"
                    --await-line "oops: fail-stop seq=1 cpu=1")
fi
python3 "$REPO_ROOT/scripts/run_kernel_crash_console.py" \
    --port "$SERIAL_PORT" --log "$UART_LOG" "${console_await[@]}" &
console_driver_pid=$!

# Fault injection is the sole GDB role before the oops. It enables the
# debugger-owned boot-test trace switch before process setup, then stops at
# run_initial_user, where x0 is the mapped EL0 entry, and replaces only that
# first user instruction. Disable that breakpoint before resuming: another
# process may enter the same routine first on a slower host, and treating that
# stop as the evidence entry makes the following frame write miss silently.
# Stop once more at the common
# evidence entry and alter the saved TPIDR_EL0 word to a deliberately distinct
# value.  This is a test-only proof that the report contains both the live
# registers and the saved exception context; the injected BRK and its vector
# path are otherwise the ordinary kernel path. In child_exec mode GDB enables
# the default-false lifecycle stop switch, detaches, and ordinary kernel flow
# reaches the same fail-stop entry after a real exec commit. GDB neither
# handles the exception nor formats its diagnostic.
armed=false
for _ in $(seq 1 50); do
    if [ "$MODE" = child_exec ]; then
        gdb_commands=(
            -ex "target remote :$GDB_PORT"
            -ex "break kernel_process_execution_reset"
            -ex "continue"
            -ex "set *(char *)&kernel_process_trace_boot_enabled = 1"
            -ex "set *(char *)&kernel_process_trace_fail_after_exec = 1"
            -ex "disable 1"
            -ex "detach"
        )
    elif [ "$MODE" = child_exec_prepare_failure ]; then
        gdb_commands=(
            -ex "target remote :$GDB_PORT"
            -ex "break kernel_process_execution_reset"
            -ex "continue"
            -ex "set *(char *)&kernel_process_trace_boot_enabled = 1"
            -ex "disable 1"
            -ex "source $REPO_ROOT/scripts/kernel_debug_metadata.gdb"
            -ex "takibi-debug-metadata $DEBUG_METADATA"
            -ex "break kernel_process_child_exec_prepare"
            -ex "continue"
            -ex "takibi-force-variant-return KernelChildExecPrepareResult CloneVmMissing"
            -ex "detach"
        )
    elif [ "$MODE" = concurrent_fault ]; then
        # QEMU's gdbstub numbers vCPUs from 1: thread 1 is core 0, thread 2
        # is core 1. With scheduler-locking on, `continue` resumes only the
        # selected vCPU and the other stays exactly where it stopped.
        #
        # 1. Core 0 stops at PID 1's first user instruction, which becomes
        #    BRK. Core 1 is online and idle: no other process exists yet.
        # 2. Core 1's idle loop calls kernel_log_peer_probe_step on every
        #    wake, and nothing else does; its first instruction becomes BRK.
        #    Core 1 alone runs, faults at EL1 and enters the fail-stop path.
        #    It is held once it has taken fault ticket 1 and the report
        #    claim, at the start of its own render. The ticket fixes the
        #    order the console must list.
        # 3. Core 0 alone runs into its BRK, through the same path, and is
        #    held at its own report claim. Both are now past the fault entry
        #    with interrupts masked, so neither can acknowledge a world stop
        #    the other begins, and neither has begun one.
        # 4. Core 0 alone runs on until its claim loop asks for the word's
        #    address a second time: it has certainly seen the claim held.
        #    Without this the renders overlapped in 8 runs of 10 and not in
        #    the other 2, and `abandoned=0` said nothing on those two. Not
        #    `stepi`: QEMU single-steps an exclusive load by running a whole
        #    block at once, and here that block read the held word as free.
        # 5. Detach releases both at once.
        gdb_commands=(
            -ex "target remote :$GDB_PORT"
            -ex "break run_initial_user thread 1"
            -ex "continue"
            -ex "set {int}\$x0 = $fault_instruction"
            -ex "delete"
            -ex "set {int}kernel_log_peer_probe_step = $fault_instruction"
            -ex "set scheduler-locking on"
            -ex "break *crash_snapshot_capture thread 2"
            -ex "thread 2"
            -ex "continue"
            -ex "delete"
            -ex "break *crash_snapshot_render thread 2"
            -ex "continue"
            -ex "delete"
            -ex "break *crash_report_claim thread 1"
            -ex "thread 1"
            -ex "continue"
            -ex "delete"
            -ex "break *crash_report_owner_address thread 1"
            -ex "continue"
            -ex "continue"
            -ex "delete"
            -ex "info threads"
            -ex "set scheduler-locking off"
            -ex "detach"
        )
    else
        gdb_commands=(
            -ex "target remote :$GDB_PORT"
        )
        if [ "$MODE" = peer_fault ]; then
            # Written at the initial -S stop, before any core has executed:
            # QEMU is halted at attach, so this is the one moment the peer's
            # entry can be replaced without racing its own bring-up. Nothing
            # else: core 0 is stopped by the peer's report before it reaches
            # userspace, so a breakpoint there would wait forever.
            gdb_commands+=(-ex "set {int}kernel_secondary_main = 0xd4200000"
                           -ex "detach")
        else
        gdb_commands+=(
            -ex "break kernel_process_execution_reset"
            -ex "continue"
            -ex "set *(char *)&kernel_process_trace_boot_enabled = 1"
            -ex "disable 1"
            -ex "break run_initial_user"
            -ex "continue"
            -ex "call (void) kernel_process_trace_report()"
            -ex "set {int}\$x0 = $fault_instruction"
            -ex "disable 2"
            -ex "break el1_exception_evidence_from_frame"
            -ex "continue"
            -ex "set {long}(\$x1 + 0x320) = 0xfeedfacefeedface"
            -ex "detach"
        )
        fi
    fi
    # Bounded: a breakpoint the kernel never reaches leaves gdb waiting in
    # `continue` for good, and concurrent_fault stages five of them. The
    # bound is well past the console driver's, which has failed by then.
    gdb_status=0
    timeout 300 gdb-multiarch -q -batch "$ELF" "${gdb_commands[@]}" \
        >"$ARTIFACT_DIR/arm-gdb.log" 2>&1 || gdb_status=$?
    if [ "$gdb_status" -eq 0 ]; then
        armed=true
        break
    fi
    if [ "$gdb_status" -eq 124 ]; then
        echo "FAIL kernel/qemu oops: GDB never reached a staged breakpoint" >&2
        sed 's/^/  /' "$ARTIFACT_DIR/arm-gdb.log" >&2 || true
        exit 1
    fi
    sleep 0.1
done
if [ "$armed" != true ]; then
    echo "FAIL kernel/qemu oops: GDB could not arm fault injection" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/arm-gdb.log" >&2 || true
    exit 1
fi

for _ in $(seq 1 50); do
    if grep -q '^ddb: read-only crash console' "$UART_LOG"; then
        break
    fi
    sleep 0.1
done

if ! wait "$console_driver_pid"; then
    console_driver_pid=""
    echo "FAIL kernel/qemu oops: read-only UART crash console did not respond" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
console_driver_pid=""

# The peer's fault is its own verdict. It is taken at EL1 during bring-up
# (slot 0, before any process exists, so no trace), its report must have
# stopped core 0 (#619, possible since #632), and it must be the only one:
# core 0, stopped, cannot fault after it.
if [ "$MODE" = peer_fault ]; then
    if ! grep -Eq "^oops: fail-stop seq=1 cpu=1 slot=0 ec=0x00000000000000$expected_ec " "$UART_LOG" ||
            ! grep -Eq '^oops: world-stop complete mask=0x0*1$' "$UART_LOG" ||
            ! grep -Eq '^oops: cores reported=1 faults=1 contended=[0-9]+ abandoned=0$' "$UART_LOG" ||
            grep -Eq '^oops: fail-stop seq=[0-9]+ cpu=0 ' "$UART_LOG"; then
        echo "FAIL kernel/qemu oops: the peer's fault did not stop core 0 and report alone" >&2
        sed 's/^/  /' "$UART_LOG" >&2 || true
        exit 1
    fi
    echo "PASS kernel/qemu oops: the peer's fail-stop stopped core 0 and reported alone"
    exit 0
fi

# GitHub issue #486's two-core claim, restored by #634. Both cores reported,
# and the console lists them in machine-wide fault order: core 1 took ticket
# 1 before core 0 was let into its fault, so the console's listing (the
# last two records in the log) must read core 1 then core 0.
#
# Every line is anchored, and that is itself the assertion: two cores
# rendering to one UART at once shred each other's lines, so an anchored
# line is the evidence that the report claim ordered every write.
#
# The console's world stop is Partial and released whichever core won the
# console: the other is inside the fail-stop path with interrupts masked and
# cannot acknowledge. That is the documented answer for a second crashing
# core, and a Complete stop here would mean one core stopped the other
# before it could report -- the scenario this mode exists to exclude.
#
# `abandoned=0` keeps the report claim honest. It counts a core that gave up
# waiting and rendered into another's output anyway -- allowed, because a
# wedged core must not silence one that still has something to say, but
# never expected on a healthy run. If it fires, CRASH_REPORT_SPIN_TURNS
# stopped outlasting one report, which wants investigating, not raising.
# `contended` of at least one says the claim was actually asked the
# question: GDB left core 0 spinning on the claim core 1 held.
if [ "$MODE" = concurrent_fault ]; then
    if ! grep -Eq "^oops: fail-stop seq=1 cpu=1 slot=0 ec=0x00000000000000$expected_ec " "$UART_LOG" ||
            ! grep -Eq "^oops: fail-stop seq=1 cpu=0 slot=8 ec=0x00000000000000$expected_ec " "$UART_LOG" ||
            ! grep -q '^oops: console owned by another core; parking$' "$UART_LOG" ||
            ! grep -Eq '^oops: world-stop partial mask=0x0+ released; other cores still run$' "$UART_LOG" ||
            grep -Eq '^oops: world-stop (complete|busy)' "$UART_LOG" ||
            ! grep -Eq '^oops: cores reported=2 faults=2 contended=[1-9][0-9]* abandoned=0$' "$UART_LOG"; then
        echo "FAIL kernel/qemu oops: two cores faulted together and the report does not show both" >&2
        sed 's/^/  /' "$UART_LOG" >&2 || true
        sed 's/^/  /' "$ARTIFACT_DIR/arm-gdb.log" >&2 || true
        exit 1
    fi
    order="$(grep '^oops: fail-stop seq=1 cpu=[01] ' "$UART_LOG" | tail -2 |
        sed 's/.*cpu=\([01]\) .*/\1/' | tr -d '\n')"
    if [ "$order" != "10" ]; then
        echo "FAIL kernel/qemu oops: the console listed the faults as '$order', not core-1-then-core-0" >&2
        sed 's/^/  /' "$UART_LOG" >&2 || true
        exit 1
    fi
    echo "PASS kernel/qemu oops: two concurrent faults both reported, in fault order"
    exit 0
fi

if ! grep -Eq "^oops: fail-stop seq=[1-9][0-9]* cpu=[0-9]+ slot=8 ec=0x00000000000000$expected_ec " "$UART_LOG" ||
        ! grep -q '^oops: saved sp_el0=' "$UART_LOG" ||
        ! grep -Eq '^oops: trace count=([1-9]|1[0-6])$' "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: expected fail-stop UART report" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if ! grep -q '^ddb: read-only crash console$' "$UART_LOG" ||
        ! grep -q '^trace count=' "$UART_LOG" ||
        ! grep -q '^ps: pid ppid state pages command$' "$UART_LOG" ||
        ! grep -Eq '^ps: 1 0 [RSZ] [0-9]+ ' "$UART_LOG" ||
        ! grep -Eq '^proc: pid=1 ppid=0 state=[RSZ] wait=[0-9]+ saved_sp=0x[0-9a-f]+ pages=[0-9]+ command=' "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: crash-console commands did not render" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
# GitHub issue #402: `asid=` is matched as "some assigned number", not as
# the literal 1 it used to be. A root's ASID is not its identity any more --
# the allocator recycles numbers by rolling the generation over, so root 0
# holds whatever number its last activation gave it. What still has to be
# true is that a running root has one at all, which a nonzero value says.
if [ "$MODE" != child_exec ] && [ "$MODE" != child_exec_prepare_failure ] &&
        { ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=7 pid=1 gen=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -Eq '^oops: process pid=1 parent=0 state=2 wait=0 wait4_status_ptr=0x0+ root=0 asid=[1-9][0-9]* .* image=bootstrap$' "$UART_LOG" ||
          ! grep -Eq '^oops: activity=[a-z-]+$' "$UART_LOG" ||
          grep -q '^oops: activity=unknown$' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu oops: expected bootstrap process trace" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if [ "$MODE" != child_exec ] && [ "$MODE" != child_exec_prepare_failure ] &&
        { ! grep -Eq '^process trace: count=([1-9]|1[0-6])$' "$UART_LOG" ||
          ! grep -Eq '^process trace: seq=[1-9][0-9]* cpu=0 event=7 pid=1 gen=[1-9][0-9]* ' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu oops: on-demand process trace report was not callable before the crash" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if [ "$MODE" != child_exec ] && [ "$MODE" != child_exec_prepare_failure ] &&
        ! grep -q ' tpidr_el0=0xfeedfacefeedface ' "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: saved TPIDR_EL0 was not retained" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

# GitHub issue #619: the core that runs the console stopped the other one
# first, so no running core can take the UART RX interrupt and eat the
# console's input. In peer_fault the console runs on core 1 and the core it
# stops is core 0.
stopped_mask=2
if [ "$MODE" = peer_fault ]; then stopped_mask=1; fi
if ! grep -Eq "^oops: world-stop complete mask=0x0*$stopped_mask\$" "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: the console ran without stopping the other core first" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

if [ "$MODE" = child_exec ] &&
        { ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=1 pid=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=2 pid=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=3 pid=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -q '^oops: exec prepare=debugger-after-commit$' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu oops: child exec lifecycle trace was incomplete" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if [ "$MODE" = child_exec_prepare_failure ] &&
        { ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=1 pid=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -q '^oops: exec prepare=clone-vm-missing$' "$UART_LOG" ||
          ! grep -q 'takibi-force-variant-return: KernelChildExecPrepareResult::CloneVmMissing via registers' "$ARTIFACT_DIR/arm-gdb.log"; }; then
    echo "FAIL kernel/qemu oops: forced child exec prepare failure was not named" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    sed 's/^/  /' "$ARTIFACT_DIR/arm-gdb.log" >&2 || true
    exit 1
fi
# GitHub issue #384: the report says WHO owns the pages it names, which is
# the lookup #373 spent a day doing by hand.  Both addresses are user VAs
# here, so this also proves the translation through the faulting process's
# own page table happened -- an untranslated VA would report "neither one
# of this allocator's pages nor mapped".
# Which of the two addresses resolves depends on the mode, and that is the
# point rather than an inconvenience: a fault injected at the first user
# instruction names a user text page in ELR, while a kernel-side fail-stop
# after an exec commit names one in FAR and has a kernel ELR.
# GitHub issue #270: child_exec mode used to require FAR to resolve too.
# That fail-stop is SVC-class -- it has no faulting address at all, so FAR
# is whatever the last real data abort left in the register, and whether
# that stale VA happens to be mapped in the exec'ing child's root is a fact
# about the process tree rather than about the report. It resolved while
# init.sh was PID 1 and does not under BusyBox init, having proved nothing
# either time. The default mode injects a real fault and still asserts the
# translation, which is where that coverage belongs; both owner lines are
# still required in every mode by the loop below.
case "$MODE" in
    child_exec|child_exec_prepare_failure) resolved= ;;
    *)          resolved=elr ;;
esac
if [ -n "$resolved" ] &&
        ! grep -Eq "^oops: $resolved page \(via root [0-9]+ -> 0x[0-9a-f]+\) is mapped into a process address space\$" \
        "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: expected the $resolved page's owner, resolved through the faulting root" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
for line in far elr; do
    if ! grep -Eq "^oops: $line page " "$UART_LOG"; then
        echo "FAIL kernel/qemu oops: expected a $line-page owner line" >&2
        sed 's/^/  /' "$UART_LOG" >&2 || true
        exit 1
    fi
done

if [ -n "$expected_detail" ] && ! grep -Eq "$expected_detail" "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: expected decoded data-abort write" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

# The CPU is confined to the read-only UART console, so the kernel-aware GDB
# command can still halt it and inspect the fixed CrashSnapshot. It reads the
# kernel's one stored object, not a
# duplicate ExceptionFrame or crash-record ABI in the test harness.
gdb-multiarch -q -batch "$ELF" \
    -ex "target remote :$GDB_PORT" \
    -ex "interrupt" \
    -ex "source $SNAPSHOT_LAYOUT" \
    -ex "source $REPO_ROOT/scripts/kernel_crash_snapshot.gdb" \
    -ex "source $REPO_ROOT/scripts/kernel_debug_metadata.gdb" \
    -ex "takibi-debug-metadata $DEBUG_METADATA" \
    -ex "source $REPO_ROOT/scripts/kernel_state.gdb" \
    -ex "takibi-oops" \
    -ex "takibi-kernel" \
    -ex "takibi-constant ProcessTrace \$snapshot[\$takibi_crashsnapshot_trace / 8 + 2]" \
    -ex "takibi-enum ProcessSlotState \$snapshot[\$takibi_crashsnapshot_trace / 8 + 7]" \
    -ex "takibi-enum ProcessWaitReason \$snapshot[\$takibi_crashsnapshot_trace / 8 + 8]" \
    >"$ARTIFACT_DIR/snapshot-gdb.log" 2>&1 || true
if ! grep -Eq '^takibi-oops: seq=1 cpu=[0-9]+ slot=8 ' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -q '^takibi-oops: saved sp_el0=' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^takibi-oops: trace count=([1-9]|1[0-6])$' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^ProcessTrace[A-Za-z]+ \([0-9]+\)$' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^ProcessSlotState::[A-Za-z]+ \([0-9]+\)$' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^ProcessWaitReason::[A-Za-z]+ \([0-9]+\)$' "$ARTIFACT_DIR/snapshot-gdb.log"; then
    echo "FAIL kernel/qemu oops: retained CrashSnapshot was not readable" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi
if ! grep -q '^takibi-kernel: ddb status=unpublished$' \
        "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^takibi-kernel: crash status=valid seq=1 cpu=[0-9]+ slot=8 ' \
        "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^takibi-kernel: crash process pid=[0-9]+ .* trace_count=([1-9]|1[0-6])$' \
        "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^takibi-kernel: crash-trace seq=[1-9][0-9]* cpu=[0-9]+ event=ProcessTrace[A-Za-z]+\([0-9]+\) ' \
        "$ARTIFACT_DIR/snapshot-gdb.log"; then
    echo "FAIL kernel/qemu oops: kernel-aware crash view was incomplete" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi
if [ "$MODE" != child_exec ] &&
        ! grep -Eq '^takibi-oops: trace seq=[1-9][0-9]* cpu=0 event=7 pid=1 gen=[1-9][0-9]* ' "$ARTIFACT_DIR/snapshot-gdb.log"; then
    echo "FAIL kernel/qemu oops: retained bootstrap trace was incomplete" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi
if [ "$MODE" = child_exec ] &&
        { ! grep -Eq '^takibi-oops: trace seq=[1-9][0-9]* cpu=0 event=1 pid=[1-9][0-9]* ' "$ARTIFACT_DIR/snapshot-gdb.log" ||
          ! grep -Eq '^takibi-oops: trace seq=[1-9][0-9]* cpu=0 event=2 pid=[1-9][0-9]* ' "$ARTIFACT_DIR/snapshot-gdb.log" ||
          ! grep -Eq '^takibi-oops: trace seq=[1-9][0-9]* cpu=0 event=3 pid=[1-9][0-9]* ' "$ARTIFACT_DIR/snapshot-gdb.log"; }; then
    echo "FAIL kernel/qemu oops: retained child exec trace was incomplete" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi

echo "PASS kernel/qemu oops: UART report and CrashSnapshot valid"
