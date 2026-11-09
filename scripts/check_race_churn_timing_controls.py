#!/usr/bin/env python3
"""Replay #692's preserved phase deadline and refuse non-timing outcomes.

Pure host evidence controls: no child process, QEMU, lease or wall-clock wait. Mutations
retain the positive timeout evidence so faults cannot pass by coincidence.
"""

import copy
import hashlib
import json
from pathlib import Path

from pass_line import report_pass
from control_patch import replace_once
from race_churn_timing import classify, load

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / 'scripts/fixtures/race633-phase-timeout'



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
        changed = replace_once(transcript.decode('ascii'), '\n--- sent QEMU',
                               '\n' + marker.decode('ascii') + '--- sent QEMU').encode('ascii')
        cases.append((log, changed, observations, 100))
    cases.extend([
        (log + '\nFAIL unrelated\n', transcript, observations, 100),
        (log.replace('no heartbeat for 120 s', 'no heartbeat for 1 s'), transcript, observations, 100),
        (log.replace('after 0 rounds', 'after 500 rounds'), transcript, observations, 100),
        (log.replace('answered=True', 'answered=False'), transcript, observations, 100),
        (log.replace('no heartbeat for 120 s after 0 rounds: the phase hung', 'unexpected runner error'), transcript, observations, 100),
        (log, b'', observations, 100),
        (log, replace_once(transcript.decode('ascii'), 'churn.sh 100', 'churn.sh 99').encode('ascii'), observations, 100),
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
    runner = (ROOT / 'scripts/run_kernel_race_window_qemutest.sh').read_text()
    assert 'if [ "$WINDOW" = 633 ] && [ "$WORKLOAD" = churn ] &&' in runner
    assert '! grep -aEq "$SIGNATURE" "$(signature_file)" &&\n        python3' in runner
    assert 'if [ "$WINDOW" = 633 ]; then' in runner
    assert 'exited & reaped & returned' in runner
    report_pass('race-churn-timing-controls',
                'preserved deadline/relocated evidence record; EOF, faults, wrong/stale phases, verdicts and missing evidence refuse; signature and trace checks remain',
                cases=len(cases), artifacts=len(provenance['curated_sha256']))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
