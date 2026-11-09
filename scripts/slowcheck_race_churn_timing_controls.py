#!/usr/bin/env python3
"""Real shell verdict/CLI controls for #692, with guest execution substituted.

The children cost over 0.5 seconds locally, so they are explicit slowcheck
work, not spawns hidden in a helper imported by the pure fast check.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from control_patch import replace_once
from pass_line import report_pass
from race_churn_timing import load

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
        runner = replace_once(runner, runner[first:last], 'run_variant() { return 1; }\n')
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
    # Missing evidence is a real nonzero CLI result with its own diagnostic.
    with tempfile.TemporaryDirectory(prefix='takibi-race633-evidence-') as tmp:
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/race_churn_timing.py'), tmp, '100'],
                                capture_output=True, text=True)
        assert result.returncode != 0
        assert 'missing or invalid evidence' in result.stdout
    count = runner_controls(log, transcript, observations)
    report_pass('race-churn-timing-shell-controls',
                'real verdict branches record only timing; faults/EOF/missing evidence gate; required signature and lifecycle trace remain',
                cases=count)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
