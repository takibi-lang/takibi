#!/usr/bin/env python3
"""Refuse stale or incomplete physical GEM fixture evidence."""
import copy
from run_kernel_gem_tx_rpi5 import BOARD, MODES, PASS, PAYLOAD, validate
from pass_line import CaseCount, report_pass

cases = CaseCount()

for mode in MODES:
    last = 'device' if mode.startswith('unconfirmed') else 'cpu'
    text = f'gem-tx fixture: mode {mode}\n'.encode()
    for authority in ('cpu', 'cpu', last, last):
        text += f'gem-tx fixture: authority {authority}\n'.encode()
    text += PASS + b'\n'
    frame = {'bytes': (bytes.fromhex('ffffffffffff') + BOARD + bytes.fromhex('88b5') + PAYLOAD).hex()}
    frames = [copy.copy(frame) for _ in range(3)]
    cases.note()
    validate(text, frames, mode)
    bad = copy.deepcopy(frames)
    bad[0]['bytes'] = bad[0]['bytes'][:-2] + '00'
    wrong_authority = text.replace(b'authority ' + last.encode(), b'authority wrong')
    for candidate, bodies in ((PASS, frames), (text.replace(PASS, b''), frames),
                              (text + b'FAIL gem-tx: failure\n', frames),
                              (text, frames[:2]), (text, frames + frames[:1]),
                              (text, bad), (wrong_authority, frames)):
        cases.note()
        try:
            validate(candidate, bodies, mode)
        except RuntimeError:
            pass
        else:
            raise SystemExit('FAIL gem-tx fixture controls: invalid evidence accepted')
report_pass('gem-tx fixture controls', 'four modes reject stale verdicts, failure markers, missing or extra transfers, corrupt payloads and wrong authorities', cases=cases.ran)
