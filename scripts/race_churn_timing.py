#!/usr/bin/env python3
"""Recognize only the evidenced reverted-633 phase timeout covered by #692.

This classifies a QEMU timing observation, not kernel progress or correctness.
The ordinary race runner still owns signature and lifecycle-trace validation.
"""

import argparse
import json
import math
from pathlib import Path
import re

from run_kernel_churn import CURSOR_QUERY, FAILURE_MARKERS, HOST_NOTICE, VERDICT, VERDICT_PREFIX

AWAIT = 'churn heartbeat, verdict or returned prompt'
DRIVER = 'kernel/qemu churn'
LANE = 'kernelcheck-race-window-633-qemu'
BREAK = b'--- sent QEMU PL011 BREAK for Takibi DDB ---'
FAILURE = re.compile(
    r"FAIL \[kernel/qemu churn\]: no heartbeat for ([0-9]+) s after ([0-9]+) rounds: "
    r"the phase hung; DDB's views are in the transcript; transcript in (.+)")
COMMAND = re.compile(rb'(?:^|\n)[ /]*# churn\.sh ([0-9]+)\n')
ERROR = re.compile(rb'Traceback \(most recent call last\):|Exception in thread|'
                   rb'(?:^|\n)(?:FAIL|ERROR)(?:[ :]|$)|'
                   rb'qemu-system-aarch64: terminating|sh: out of memory')

# Only the saved socket-close race after the completed postmortem is teardown,
# not an arbitrary traceback. Keep every frame/code line constrained.
RX_CLOSE = re.compile(
    rb"Exception in thread rx:\nTraceback \(most recent call last\):\n"
    rb'  File "[^"\n]*/threading.py", line [0-9]+, in _bootstrap_inner\n'
    rb'    self.run\(\)\n'
    rb'  File "[^"\n]*/threading.py", line [0-9]+, in run\n'
    rb'    self._target\(\*self._args, \*\*self._kwargs\)\n'
    rb'  File "[^"\n]*/run_kernel_shell_console.py", line [0-9]+, in reader\n'
    rb'    data = self.serial.read\(self.serial.in_waiting or 1\)\n'
    rb'(?: +\^+\n)?'
    rb'  File "[^"\n]*/serial/urlhandler/protocol_socket.py", line [0-9]+, in read\n'
    rb'    buf = self._socket.recv\(size - len\(read\)\)\n'
    rb'(?: +\^+\n)?'
    rb"AttributeError: 'NoneType' object has no attribute 'recv'\n")
QEMU_CLOSE = re.compile(rb'qemu-system-aarch64: terminating on signal 15 from pid [0-9]+ \(bash\)')


def classify(log, transcript, observations, rounds):
    """Return None only for the one evidenced timing-only outcome; else why.

    observations is ordered (sidecar basename, row) pairs. Absolute original
    source paths may differ after archival or fixture relocation.
    """
    failures = [line for line in log.splitlines() if line.startswith('FAIL')]
    if len(failures) != 1 or not (failure := FAILURE.fullmatch(failures[0])):
        return 'not the sole explicit churn heartbeat timeout'
    if rounds <= 0 or int(failure[1]) <= 0:
        return 'invalid workload or timeout'
    if Path(failure[3]).parts[-2:] != ('kernel-churn-qemu', 'churn-transcript.log'):
        return 'failure does not name the churn transcript'
    resync = [line for line in log.splitlines() if line.startswith('[churn resync]')]
    if not resync or ' answered=True ' not in resync[-1]:
        return 'no successful phase resync'
    normalized = HOST_NOTICE.sub(b'', transcript.replace(b'\r', b'').replace(CURSOR_QUERY, b''))
    commands = list(COMMAND.finditer(normalized))
    # This wrapper runs one phase, not --long. Multiple phase echoes would
    # make an older timed-out sidecar ambiguous, so do not infer association.
    if len(commands) != 1 or int(commands[0][1]) != rounds:
        return 'missing, wrong or ambiguous churn phase command'
    phase = normalized[commands[0].end():]
    if any(marker in phase for marker in FAILURE_MARKERS if marker != b'ddb> '):
        return 'explicit kernel fault in the phase or postmortem'
    verdicts = list(VERDICT.finditer(phase))
    if phase.count(VERDICT_PREFIX) != len(verdicts) or any(
            int(v[1]) != rounds or int(v[2]) != 0 for v in verdicts):
        return 'unexpected or malformed functional verdict'
    postmortem = phase.find(BREAK)
    if postmortem < 0 or b'ddb> ' in phase[:postmortem]:
        return 'missing postmortem boundary or unexpected debugger entry'
    trace = phase.find(b'ddb: trace count=', postmortem)
    finished = phase.find(b'ddb> ', trace) if trace >= 0 else -1
    if trace < 0 or finished < 0 or b'ddb: ps count=' not in phase[postmortem:trace]:
        return 'missing completed postmortem evidence'
    # The saved case has a socket-reader exception after its final DDB prompt,
    # during deliberate terminal shutdown. Never ignore an earlier transport
    # error/EOF: errors through completion of the postmortem still refuse.
    if ERROR.search(phase[:finished]):
        return 'transport or explicit failure before diagnostic teardown'
    teardown = phase[finished:]
    if len(RX_CLOSE.findall(teardown)) > 1:
        return 'multiple reader failures are not the known teardown'
    teardown = RX_CLOSE.sub(b'', teardown)
    teardown = QEMU_CLOSE.sub(b'', teardown)
    if ERROR.search(teardown):
        return 'unrecognized failure during teardown'
    waits = [(name, row) for name, row in observations if row.get('await') == AWAIT]
    if not waits:
        return 'no phase await evidence'
    if any(row.get('status') != 'arrived' for _, row in waits[:-1]):
        return 'an earlier unresolved phase makes the evidence ambiguous'
    name, row = waits[-1]
    if (row.get('driver') != DRIVER or row.get('lane') != LANE or
            row.get('budget_origin') != 'console wait start' or
            row.get('status') != 'not-arrived' or row.get('elapsed_seconds') is not None or
            Path(str(row.get('source', ''))).name != name):
        return 'phase await identity/outcome does not match'
    timeout, observed = row.get('timeout_seconds'), row.get('observed_seconds')
    if any(type(value) not in (int, float) or not math.isfinite(value)
           for value in (timeout, observed)):
        return 'invalid deadline measurement'
    if timeout <= 0 or observed < timeout:
        return 'wait ended before its deadline (including early EOF)'
    if timeout != int(failure[1]):
        return 'failure timeout disagrees with the measured deadline'
    progress = [int(value) for value in re.findall(
        rb'(?:^|\n)churn: progress ([0-9]+)\n', phase[:postmortem])]
    if (progress != [500 * (i + 1) for i in range(len(progress))] or
            int(failure[2]) != 500 * len(progress) or int(failure[2]) > rounds):
        return 'failure heartbeat count disagrees with this phase'
    if (not progress and len(waits) != 1) or len(waits) - 1 > len(progress):
        return 'await history does not belong to this phase progress'
    return None


def load(root):
    directory = root / 'reverted' / 'kernel-churn-qemu'
    observations = []
    for path in sorted(directory.glob('churn-transcript.log.await-*.jsonl')):
        rows = path.read_text(encoding='ascii').splitlines()
        if len(rows) != 1:
            raise ValueError('an await sidecar must contain exactly one row')
        row = json.loads(rows[0])
        if not isinstance(row, dict):
            raise ValueError('await row is not an object')
        observations.append((path.name, row))
    return ((root / 'reverted.log').read_text(encoding='ascii'),
            (directory / 'churn-transcript.log').read_bytes(), observations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('rounds', type=int)
    args = parser.parse_args()
    try:
        reason = classify(*load(args.root), args.rounds)
    except (OSError, ValueError, TypeError) as error:
        reason = f'missing or invalid evidence: {error}'
    if reason is not None:
        print('race633 timing not recorded: ' + reason)
        return 1
    print('RECORDED kernel/qemu race-window 633: reverted churn heartbeat deadline expired; '
          'no functional fault shown; QEMU timing observation under #692, not proof of guest progress')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
