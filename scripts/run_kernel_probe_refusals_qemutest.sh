#!/usr/bin/env bash
# Run the actual boot probes with their secondary entries suppressed. Capture
# every refusal before any normal-suite failure handler can enter DDB early.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${KERNEL_PROBE_REFUSALS_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-probe-refusals-qemu}"
ELF="${KERNEL_PROBE_REFUSALS_ELF:-$REPO_ROOT/kernel/build/qemu/kernel-race-651-no-peer-reverted.elf}"
if [ "${KERNEL_PROBE_REFUSALS_CONTROL:-normal}" = admitted-drain ]; then
    ELF="$REPO_ROOT/kernel/build/qemu/kernel-race-1517-admitted-drain-armed.elf"
    ARTIFACT_DIR="$ARTIFACT_DIR/admitted-drain"
fi
mkdir -p "$ARTIFACT_DIR"
trap 'status=$?; if [ "$status" -ne 0 ]; then bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" "$ARTIFACT_DIR" "${ARTIFACT_DIR}-failures" "probe refusal controls failed"; fi' EXIT
if [ "${KERNEL_PROBE_REFUSALS_CONTROL:-normal}" = old-baseline ]; then
    # The real pre-stop sample, with a tick forced before the stop, must not
    # be accepted as evidence of resume. Prove status and diagnosis separately.
    # GitHub issue #883: this child is meant to fail, and its archive is the
    # evidence the old baseline was refused, not a failure of this lane.
    if env KERNEL_PROBE_REFUSALS_CONTROL=normal \
        TAKIBI_ARCHIVE_EXPECTED="probe-refusals old resume baseline, meant to fail" \
        KERNEL_PROBE_REFUSALS_ELF="$REPO_ROOT/kernel/build/qemu/kernel-race-651-resume-old-reverted.elf" \
        KERNEL_PROBE_REFUSALS_ARTIFACT_DIR="$ARTIFACT_DIR/old-baseline" \
        bash "$0" >"$ARTIFACT_DIR/old-baseline.log" 2>&1; then
        echo "FAIL probe-refusals: old resume baseline passed the refusal test" >&2
        exit 1
    fi
    # These are host-oracle diagnostics, not kernel UART expectations.
    python3 - "$ARTIFACT_DIR/old-baseline.log" <<'PYCONTROL'
import pathlib
import sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
for expected in ('FAIL probe-refusals: world stop resume accepted a stale tick',
                 'FAIL probe-refusals: signal retried an invalid phase'):
    if expected not in lines:
        print('\n'.join(lines), file=sys.stderr)
        raise SystemExit('FAIL probe-refusals: old control lacked its own diagnosis: ' + expected)
PYCONTROL
    echo "PASS probe-refusals control: old resume baseline and signal loop fail with their own diagnoses"
    exit 0
fi
. "$REPO_ROOT/scripts/kernel_elf_freshness.sh"
kernel_elf_refuse_stale "$ELF" || exit 1
mkdir -p "$ARTIFACT_DIR"
. "$REPO_ROOT/scripts/vcpu_lease.sh"
resource_lease_vcpu_acquire "$TAKIBI_QEMU_SMP"
python3 - "$REPO_ROOT" "$ARTIFACT_DIR" "$ELF" <<'PY'
import os
import pathlib
import signal
import shutil
import subprocess
import sys
import time

root, artifacts, elf = map(pathlib.Path, sys.argv[1:])
disk = artifacts / 'ext2.img'
shutil.copyfile(root / 'kernel/build/user/ext2.img', disk)
uart = artifacts / 'uart.log'
uart.write_bytes(b'')
admitted_drain = os.environ.get('KERNEL_PROBE_REFUSALS_CONTROL') == 'admitted-drain'
marker = 'probe-ticks: missing-peer controls complete'
departed = 'signal drain fixture: peer left abandoned record'
next_probe = 'world stop from a peer: '

def capture_complete(text):
    if admitted_drain:
        return departed in text and any(
            line.startswith(next_probe) for line in text.splitlines())
    return marker in text

command = [str(root / 'scripts/qemu.sh'), '-machine', 'virt', '-cpu', 'cortex-a76',
           '-smp', os.environ['TAKIBI_QEMU_SMP'], '-m', '1024', '-display', 'none', '-monitor', 'none',
           '-serial', 'file:' + str(uart),
           '-drive', f'file={disk},if=none,format=raw,id=vd0',
           '-device', 'virtio-blk-device,drive=vd0',
           '-netdev', 'hubport,id=net0,hubid=0',
           '-device', 'virtio-net-device,netdev=net0,mac=02:00:20:00:00:02',
           '-kernel', str(elf)]
start = time.monotonic()
def interrupted(signum, frame):
    raise SystemExit('FAIL probe-refusals: interrupted')

signal.signal(signal.SIGTERM, interrupted)
with (artifacts / 'qemu.log').open('wb') as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    try:
        while not capture_complete(uart.read_text(errors='replace')):
            if process.poll() is not None:
                raise SystemExit('FAIL probe-refusals: QEMU exited before all probes returned')
            if time.monotonic() - start >= 180:
                raise SystemExit('FAIL probe-refusals: missing completion marker; see uart.log')
            time.sleep(0.1)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
# GitHub issue #1033: QEMU has stopped; the host's e2fsprogs judge the disk.
if subprocess.run([sys.executable, str(root / 'scripts/ext2_postcheck.py'),
                   '--label', 'kernel/qemu probe-refusals', '--image', str(disk),
                   '--out', str(artifacts), '--uart-log', str(uart)]).returncode:
    raise SystemExit('FAIL probe-refusals: the guest\'s ext2 disk failed its postcheck')
text = uart.read_text(errors='replace').replace('\r', '')
if admitted_drain:
    lines = text.splitlines()
    opened = 'signal drain fixture: opened'
    admitted = 'signal drain fixture: peer admitted'
    timed_out = 'signal contention stage: secondary-never-left'
    failed = 'signal contention: failed'
    reset = 'signal drain fixture: reset'

    def validate_drain(events):
        ordered = (opened, admitted, timed_out, failed)
        if any(events.count(event) != 1 for event in (*ordered, departed)):
            return False
        if any(events.index(a) >= events.index(b)
               for a, b in zip(ordered, ordered[1:])):
            return False
        return reset not in events and any(
            event.startswith(next_probe) for event in events[events.index(failed) + 1:])

    if not validate_drain(lines):
        raise SystemExit('FAIL probe-refusals: admitted peer drain evidence incomplete')
    # Change only the observed trace. The guest never runs a reuse mutation.
    for event in (opened, reset):
        if validate_drain(lines + [event]):
            raise SystemExit('FAIL probe-refusals: drain oracle accepted reuse evidence')
    print('PASS probe-refusals: admitted peer timed out, left an abandoned '
          f'record, and boot continued; synthetic reuse refused; {time.monotonic() - start:.1f}s')
    raise SystemExit(0)
names = ('console contention', 'schedule contention',
         'pid contention', 'fd refcount contention', 'asid contention',
         'page contention', 'freelist contention', 'pool contention',
         'occupancy drain', 'network init contention',
         'tcp fixture claim contention', 'tcp owner contention',
         'pool walk', 'ext2 mutation contention', 'signal contention',
         'world stop from a peer', 'world stop')
lines = text.splitlines()
for name in names:
    if lines.count(name + ': failed') != 1:
        raise SystemExit(f'FAIL probe-refusals: expected one actual refusal from {name}')
for name, reason in (
        ('schedule contention', 'secondary-never-completed-a-round'),
        ('asid contention', 'secondary-never-completed-a-round'),
        ('page contention', 'secondary-never-completed-a-round'),
        ('pid contention', 'secondary-never-entered'),
        ('fd refcount contention', 'secondary-never-entered'),
        ('freelist contention', 'secondary-never-entered'),
        ('pool contention', 'secondary-never-entered'),
        ('occupancy drain', 'secondary-never-entered'),
        ('pool walk', 'secondary-never-entered')):
    if name + ' stage: ' + reason not in lines:
        raise SystemExit(f'FAIL probe-refusals: missing named entry diagnosis from {name}')
if 'ext2 mutation contention stage: peer-never-asked-unheld' not in lines:
    raise SystemExit('FAIL probe-refusals: missing named ext2 arrival diagnosis')
for line in ('world stop stage: secondary-never-acknowledged',
             'console contention stage: secondary-never-ready',
             'network init contention stage: secondary-never-arrived',
             'tcp fixture claim contention stage: secondary-never-arrived',
             'tcp owner contention stage: secondary-never-finished',
             'signal contention stage: secondary-missed-round',
             'world stop from a peer stage: secondary-never-finished'):
    if line not in lines:
        raise SystemExit(f'FAIL probe-refusals: missing named refusal: {line}')
errors = []
if 'world stop resume control: refused' not in lines:
    errors.append('FAIL probe-refusals: world stop resume accepted a stale tick')
# One timed-out round ends the fixture. The subsequent peer world-stop probe
# and the completion marker witness that the boot driver continued.
if (lines.index('signal contention: failed') >= lines.index('world stop from a peer: failed')
        or lines.index('world stop from a peer: failed') >= lines.index(marker)):
    errors.append('FAIL probe-refusals: boot did not continue after signal timeout')
if 'signal phase control attempts: 1' not in lines:
    errors.append('FAIL probe-refusals: signal retried an invalid phase')
if errors:
    print('\n'.join(errors))
    raise SystemExit(1)
print(f'PASS probe-refusals: {len(names)} real probes refused a missing participant; '
      f'signal timeout returned to boot after one attempt; stale resume refused; completed in {time.monotonic() - start:.1f}s')
PY
