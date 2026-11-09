#!/usr/bin/env python3
"""Replay #692's preserved phase deadline and refuse non-timing outcomes.

Pure host evidence controls: no QEMU, lease, pty or wall-clock wait. Mutations
retain the positive timeout evidence so faults cannot pass by coincidence.
"""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from pass_line import report_pass
from race_churn_timing import classify, load

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / 'scripts/fixtures/race633-phase-timeout'


def runner_controls(log, transcript, observations):
    """Run the real shell verdict branches, replacing only guest execution.

    Port/archive helpers are inert stand-ins: this is a host decision test,
    never a QEMU launch, port-registry access, lease or wall-clock wait.
    """
    signature = '^ddb: wait pid=([3-9]|[1-9][0-9]+) state=blocked waits-for event=signal'
    signal_line = b'\nddb: wait pid=4 state=blocked waits-for event=signal\n'
    cases = [
        ('deadline', log, transcript, observations, 0, 'RECORDED kernel/qemu race-window 633:'),
        ('unrelated', log + '\nFAIL unrelated failure\n', transcript, observations, 1, 'but no line matched'),
        ('fault', log, transcript + b'\noops: fail-stop\n', observations, 1, 'but no line matched'),
        ('eof', log, transcript, [(observations[0][0], dict(observations[0][1], observed_seconds=1))],
         1, 'but no line matched'),
        ('missing', log, None, observations, 1, 'but no line matched'),
        ('signature', log, transcript + signal_line, observations, 0, 'trace: child 322 exit, reap and wait4 return shown'),
        ('bad-trace', log, transcript.replace(b'event=9 pid=322', b'event=7 pid=322') + signal_line,
         observations, 1, 'no child with exit, reap and wait4 return'),
    ]
    with tempfile.TemporaryDirectory(prefix='takibi-race633-runner-') as tmp:
        tree = Path(tmp)
        scripts = tree / 'scripts'
        scripts.mkdir()
        for original in (ROOT / 'scripts').glob('*.py'):
            (scripts / original.name).symlink_to(original)
        runner = (ROOT / 'scripts/run_kernel_race_window_qemutest.sh').read_text()
        first, last = runner.index('run_variant() {'), runner.index('\nsignature_file()')
        runner = runner[:first] + 'run_variant() { return 1; }\n' + runner[last:]
        (scripts / 'runner.sh').write_text(runner)
        (scripts / 'qemu_port_guard.py').unlink()
        (scripts / 'qemu_port_guard.py').write_text('raise SystemExit(0)\n')
        (scripts / 'qemu_session_ports.sh').write_text('qemu_session_shift_ports() { :; }\n')
        (scripts / 'archive_kernel_failure.sh').write_text('exit 0\n')
        for name, case_log, case_transcript, rows, expected_status, expected_text in cases:
            root = tree / name / '633'
            directory = root / 'reverted/kernel-churn-qemu'
            directory.mkdir(parents=True)
            (root / 'reverted.log').write_text(case_log)
            if case_transcript is not None:
                (directory / 'churn-transcript.log').write_bytes(case_transcript)
            for filename, row in rows:
                (directory / filename).write_text(json.dumps(row) + '\n')
            env = dict(os.environ, KERNEL_QEMU_RACE_WINDOW='633',
                       KERNEL_QEMU_RACE_WINDOW_WORKLOAD='churn',
                       KERNEL_QEMU_RACE_WINDOW_ARMED='skip',
                       KERNEL_QEMU_RACE_WINDOW_SIGNATURE=signature,
                       KERNEL_QEMU_RACE_WINDOW_CHURN_ROUNDS='100',
                       KERNEL_QEMU_RACE_WINDOW_REQUIRE_FAILURE='0',
                       KERNEL_QEMU_RACE_WINDOW_ARTIFACT_DIR=str(root.parent))
            result = subprocess.run(['bash', str(scripts / 'runner.sh')], env=env,
                                    capture_output=True, text=True)
            output = result.stdout + result.stderr
            assert (result.returncode == 0) == (expected_status == 0), (name, output)
            assert expected_text in output, (name, output)
            if expected_status:
                assert 'RECORDED kernel/qemu race-window 633:' not in output
    return len(cases)


def main():
    log, transcript, observations = load(FIXTURE)
    assert classify(log, transcript, observations, 100) is None
    provenance = json.loads((FIXTURE / 'provenance.json').read_text())
    for path, digest in provenance['curated_sha256'].items():
        assert hashlib.sha256((FIXTURE / path).read_bytes()).hexdigest() == digest
    cases = []
    def mutated(**changes):
        row = copy.deepcopy(observations)
        row[0][1].update(changes)
        return row
    for text in ('\nFAIL unrelated functional failure\n', '\nERROR unrelated\n',
                 '\noops: fail-stop\n', '\nsched: STARVED\n',
                 '\nchurn: rounds=100 mismatched=1\n', '\nchurn: rounds=99 mismatched=0\n',
                 '\nchurn: rounds=unknown\n', '\nTraceback (most recent call last):\nRuntimeError: other\n'):
        cases.append((log, transcript + text.encode(), observations, 100))
    for marker in (b'Traceback (most recent call last):\n', b'Exception in thread rx:\n',
                   b'qemu-system-aarch64: terminating on signal 15 from pid 7 (bash)\n',
                   b'FAIL unrelated\n', b'ddb> '):
        changed = transcript.replace(b'\n--- sent QEMU', b'\n' + marker + b'--- sent QEMU', 1)
        cases.append((log, changed, observations, 100))
    cases.extend([
        (log + '\nFAIL unrelated\n', transcript, observations, 100),
        (log.replace('no heartbeat for 120 s', 'no heartbeat for 1 s'), transcript, observations, 100),
        (log.replace('after 0 rounds', 'after 500 rounds'), transcript, observations, 100),
        (log.replace('answered=True', 'answered=False'), transcript, observations, 100),
        (log.replace('no heartbeat for 120 s after 0 rounds: the phase hung', 'unexpected runner error'), transcript, observations, 100),
        (log, b'', observations, 100),
        (log, transcript.replace(b'churn.sh 100', b'churn.sh 99', 1), observations, 100),
        (log, transcript + b'\n # churn.sh 100\n', observations, 100),
        (log, transcript.replace(b'ddb: trace count=', b'no trace count='), observations, 100),
        (log, transcript, [], 100),
        (log, transcript, observations + copy.deepcopy(observations), 100),
        (log, transcript, mutated(status='arrived'), 100),
        (log, transcript, mutated(observed_seconds=0.5), 100),
        (log, transcript, mutated(timeout_seconds=900), 100),
        (log, transcript, mutated(timeout_seconds=0), 100),
        (log, transcript, mutated(observed_seconds=float('nan')), 100),
        (log, transcript, mutated(timeout_seconds=True), 100),
        (log, transcript, mutated(driver='kernel/rpi5 churn'), 100),
        (log, transcript, mutated(lane='kernelcheck-race-window-609-qemu'), 100),
        (log, transcript, mutated(source='/other/older.await.jsonl'), 100),
        (log, transcript, mutated(**{'await': 'older phase'}), 100),
        (log, transcript, mutated(elapsed_seconds=120), 100),
    ])
    for case in cases:
        assert classify(*case) is not None, case[0][-200:]
    relocated = mutated(source='/relocated/capture/' + observations[0][0])
    assert classify(log, transcript, relocated, 100) is None
    # Missing evidence is a real nonzero CLI result with its own diagnostic.
    with tempfile.TemporaryDirectory(prefix='takibi-race633-evidence-') as tmp:
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/race_churn_timing.py'), tmp, '100'],
                                capture_output=True, text=True)
        assert result.returncode != 0
        assert 'missing or invalid evidence' in result.stdout
    runner = (ROOT / 'scripts/run_kernel_race_window_qemutest.sh').read_text()
    assert 'if [ "$WINDOW" = 633 ] && [ "$WORKLOAD" = churn ] &&' in runner
    assert '! grep -aEq "$SIGNATURE" "$(signature_file)" &&\n        python3' in runner
    assert 'if [ "$WINDOW" = 633 ]; then' in runner
    assert 'exited & reaped & returned' in runner
    runner_cases = runner_controls(log, transcript, observations)
    report_pass('race-churn-timing-controls',
                'preserved deadline/relocated evidence record; EOF, faults, wrong/stale phases, verdicts and missing evidence refuse; signature and trace checks remain',
                cases=len(cases) + runner_cases, artifacts=len(provenance['curated_sha256']))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
