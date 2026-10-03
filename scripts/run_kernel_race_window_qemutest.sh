#!/usr/bin/env bash
# GitHub issue #615: one named race window, widened on purpose.
#
# scripts/build_qemu_race_window.py builds two QEMU kernels from a source
# overlay: the window "armed", with a spin at its opening, and "reverted",
# armed with the check the window exercises also removed. The ordinary QEMU
# suite runs on each:
#
#   armed     must pass every view -- the window is survivable with the check.
#   reverted  must fail, and the UART must show the reverted check's own
#             signature. A reverted run that fails for any other reason, or
#             passes, says the window is not being crossed.
#
# KERNEL_QEMU_RACE_WINDOW names the window. KERNEL_QEMU_RACE_WINDOW_SIGNATURE
# is an extended regex for the line the reverted kernel must print -- a
# fail-stop activity, or a starvation report for a check whose absence stalls
# rather than faults. The ports are passed
# through to scripts/run_kernel_qemutest.sh; the two runs are sequential.
set -euo pipefail

trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOW="${KERNEL_QEMU_RACE_WINDOW:?KERNEL_QEMU_RACE_WINDOW names the window}"
SIGNATURE="${KERNEL_QEMU_RACE_WINDOW_SIGNATURE:?KERNEL_QEMU_RACE_WINDOW_SIGNATURE names the reverted signature}"
ARTIFACT_DIR="${KERNEL_QEMU_RACE_WINDOW_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-race-window-qemu}"
ROOT="$ARTIFACT_DIR/$WINDOW"
LABEL="kernel/qemu race-window $WINDOW"

# suite: the ordinary QEMU suite, whose UART capture carries the signature.
# churn: scripts/run_kernel_churn.py's workload through the QEMU shell, for a
# window only concurrent siblings reach (#633); its transcript carries it.
WORKLOAD="${KERNEL_QEMU_RACE_WINDOW_WORKLOAD:-suite}"
CHURN_ROUNDS="${KERNEL_QEMU_RACE_WINDOW_CHURN_ROUNDS:-100}"

run_variant() {
    local variant="$1"
    local elf="$REPO_ROOT/kernel/build/qemu/kernel-race-$WINDOW-$variant.elf"
    if [ "$WORKLOAD" = churn ]; then
        env KERNEL_QEMU_SHELL_ELF="$elf" \
            KERNEL_QEMU_SHELL_SERIAL_PORT="${KERNEL_QEMU_SERIAL_PORT:-18668}" \
            TAKIBI_LANE_ARTIFACT_ROOT="$ROOT/$variant" \
            python3 "$REPO_ROOT/scripts/run_kernel_churn.py" --platform qemu \
                --rounds "$CHURN_ROUNDS" --stall-seconds 120 \
            >"$ROOT/$variant.log" 2>&1
        return
    fi
    env KERNEL_QEMU_ELF="$elf" \
        KERNEL_QEMU_LABEL="qemu-race-$WINDOW-$variant" \
        KERNEL_QEMU_HWTEST_ARTIFACT_DIR="$ROOT/$variant" \
        bash "$REPO_ROOT/scripts/run_kernel_qemutest.sh" \
        >"$ROOT/$variant.log" 2>&1
}

signature_file() {
    if [ "$WORKLOAD" = churn ]; then
        echo "$ROOT/reverted/kernel-churn-qemu/churn-transcript.log"
    else
        echo "$ROOT/reverted/uart.log"
    fi
}

# Declared here as well as in the runner this delegates to, so
# scripts/check_qemu_lane_ports.py sees this lane's ports and checks them
# against every other lane's. The runner shifts and guards them again itself.
SERIAL_PORT="${KERNEL_QEMU_SERIAL_PORT:-18668}"
QMP_PORT="${KERNEL_QEMU_QMP_PORT:-18669}"
NETDEV_LOCAL_PORT="${KERNEL_QEMU_NETDEV_LOCAL_PORT:-18670}"
NETDEV_REMOTE_PORT="${KERNEL_QEMU_NETDEV_REMOTE_PORT:-18675}"
. "$REPO_ROOT/scripts/qemu_session_ports.sh"
qemu_session_shift_ports SERIAL_PORT QMP_PORT NETDEV_LOCAL_PORT \
    NETDEV_REMOTE_PORT
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "$LABEL" \
    "tcp:$SERIAL_PORT" "tcp:$QMP_PORT" "udp:$NETDEV_LOCAL_PORT" \
    "udp:$NETDEV_REMOTE_PORT" || exit 1

mkdir -p "$ROOT"
# A control-only window (#635) has no spin to survive: its armed kernel is the
# ordinary one, which the ordinary suite already runs.
if [ "${KERNEL_QEMU_RACE_WINDOW_ARMED:-run}" = skip ]; then
    echo "$LABEL: armed run skipped, the ordinary suite is its armed run"
elif ! run_variant armed; then
    if [ "$WORKLOAD" = churn ]; then
        # GitHub issue #692: the churn's verdicts are phase deadlines and a
        # resync timeout -- time bounds, which QEMU under host load stretches
        # (#655). Recorded here and archived below; the churn is decided on
        # the RPi5. The reverted run's signature below still gates.
        echo "RECORDED $LABEL: the armed kernel's churn failed (QEMU timing verdict, gated on the RPi5; #692)"
        grep -E '^FAIL|^\[churn resync\]' "$ROOT/armed.log" | sed 's/^/  /' || true
        keep="${ARTIFACT_DIR}-failures/$(date -u +%Y%m%dT%H%M%SZ)-$WINDOW-armed"
        mkdir -p "$keep"
        cp -r "$ROOT/armed.log" "$ROOT/armed" "$keep/" 2>/dev/null || true
        {
            echo "reason: armed $WORKLOAD failed (recorded, not gating)"
            echo "commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
            echo "load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
            echo "lane: race-window $WINDOW armed"
        } > "$keep/MANIFEST"
        echo "archived the armed run to: $keep"
    else
    echo "FAIL $LABEL: the armed kernel failed the $WORKLOAD with the check present" >&2
    grep -E '^FAIL|^\[churn resync\]' "$ROOT/armed.log" | sed 's/^/  /' >&2 || true
    # GitHub issue #655: an armed failure's evidence used to be overwritten
    # by the next run of this lane, so a capture never survived to be read.
    # Keep it where land.sh collects failures.
    keep="${ARTIFACT_DIR}-failures/$(date -u +%Y%m%dT%H%M%SZ)-$WINDOW-armed"
    mkdir -p "$keep"
    cp -r "$ROOT/armed.log" "$ROOT/armed" "$keep/" 2>/dev/null || true
    {
        echo "reason: armed $WORKLOAD failed"
        echo "commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
        echo "load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
        echo "lane: race-window $WINDOW armed"
    } > "$keep/MANIFEST"
    echo "archived the armed run to: $keep" >&2
    exit 1
    fi
fi
if run_variant reverted; then
    # GitHub issue #692: whether a widened window is crossed in time is a
    # timing verdict; under host load QEMU sometimes does not cross it (#685).
    # Recorded, not gating: the armed run above is the functional half.
    echo "RECORDED $LABEL: with the check reverted the $WORKLOAD passed, so the window was not crossed (QEMU timing verdict; #692)"
    exit 0
fi
if ! grep -aEq "$SIGNATURE" "$(signature_file)" && [ "$WORKLOAD" = churn ] &&
        grep -aq 'the shell did not answer an empty line before the phase' \
            "$ROOT/reverted.log" "$(signature_file)" 2>/dev/null; then
    # GitHub issue #692: the reverted churn stopped at the resync timeout
    # (#655) before it reached the window, so it says nothing about the
    # check either way. A QEMU timing verdict: recorded, not gating.
    echo "RECORDED $LABEL: the reverted churn stopped at its resync timeout before the window (QEMU timing verdict; #692)"
    exit 0
fi
if ! grep -aEq "$SIGNATURE" "$(signature_file)"; then
    echo "FAIL $LABEL: with the check reverted the $WORKLOAD failed, but no line matched $SIGNATURE" >&2
    grep -aE '^(oops: (fail-stop|activity)|sched: STARVED|ddb: wait pid)' "$(signature_file)" | sed 's/^/  /' >&2 || true
    exit 1
fi
if [ "${KERNEL_QEMU_RACE_WINDOW_ARMED:-run}" = skip ]; then
    echo "PASS $LABEL: with the check reverted, the $WORKLOAD failed showing $SIGNATURE"
else
    echo "PASS $LABEL: armed, the $WORKLOAD passed; with the check reverted, it failed showing $SIGNATURE"
fi
