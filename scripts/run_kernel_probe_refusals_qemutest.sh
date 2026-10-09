#!/usr/bin/env bash
# Run the actual boot probes with their secondary entries suppressed. Capture
# every refusal before any normal-suite failure handler can enter DDB early.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${KERNEL_PROBE_REFUSALS_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-probe-refusals-qemu}"
ELF="${KERNEL_PROBE_REFUSALS_ELF:-$REPO_ROOT/kernel/build/qemu/kernel-race-651-no-peer-reverted.elf}"
mkdir -p "$ARTIFACT_DIR"
trap 'status=$?; if [ "$status" -ne 0 ]; then bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" "$ARTIFACT_DIR" "${ARTIFACT_DIR}-failures" "probe refusal controls failed"; fi' EXIT
if [ "${KERNEL_PROBE_REFUSALS_CONTROL:-normal}" = old-baseline ]; then
    # The real pre-stop sample, with a tick forced before the stop, must not
    # be accepted as evidence of resume. Prove status and diagnosis separately.
    if env KERNEL_PROBE_REFUSALS_CONTROL=normal \
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
python3 - "$REPO_ROOT" "$ARTIFACT_DIR" "$ELF" <<'PY'
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
marker = 'probe-ticks: missing-peer controls complete'
command = ['qemu-system-aarch64', '-machine', 'virt', '-cpu', 'cortex-a53',
           '-smp', '2', '-m', '1024', '-display', 'none', '-monitor', 'none',
           '-serial', 'file:' + str(uart), '-global', 'virtio-mmio.force-legacy=on',
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
        while marker not in uart.read_text(errors='replace'):
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
text = uart.read_text(errors='replace').replace('\r', '')
names = ('console contention', 'schedule contention', 'tag contention',
         'pid contention', 'fd refcount contention', 'asid contention',
         'page contention', 'freelist contention', 'pool contention',
         'occupancy drain', 'network init contention', 'tcp owner contention',
         'pool walk', 'ext2 mutation contention', 'signal contention',
         'world stop from a peer', 'world stop')
lines = text.splitlines()
for name in names:
    if lines.count(name + ': failed') != 1:
        raise SystemExit(f'FAIL probe-refusals: expected one actual refusal from {name}')
for name, reason in (
        ('schedule contention', 'secondary-never-completed-a-round'),
        ('tag contention', 'secondary-never-completed-a-round'),
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
             'tcp owner contention stage: secondary-never-finished',
             'signal contention stage: secondary-missed-round',
             'world stop from a peer stage: secondary-never-finished'):
    if line not in lines:
        raise SystemExit(f'FAIL probe-refusals: missing named refusal: {line}')
errors = []
if 'world stop resume control: refused' not in lines:
    errors.append('FAIL probe-refusals: world stop resume accepted a stale tick')
if 'signal phase control attempts: 2' not in lines:
    errors.append('FAIL probe-refusals: signal retried an invalid phase')
if errors:
    print('\n'.join(errors))
    raise SystemExit(1)
print(f'PASS probe-refusals: {len(names)} real probes refused a missing participant; '
      f'entry diagnoses and stale-resume refusal retained; completed in {time.monotonic() - start:.1f}s')
PY
