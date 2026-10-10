#!/usr/bin/env python3
"""Refuse stale or incomplete physical GEM fixture evidence."""
import copy
from run_kernel_gem_tx_rpi5 import BOARD, MODES, PASS, PAYLOAD, IRQ_PASS, validate, validate_irq
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
# Require genuine IRQ witnesses and complete timestamp records, not merely
# a quick successful send that a poll could have produced.
for mode in ('irq-primary', 'irq-wrong-enable'):
    def evidence(delta=1, duration=10, frequency=1000000):
        text = f'gem-probe: mode {mode}\ngem-probe: frequency={frequency}\n'
        for sample in range(32):
            start = 100000 + sample * 20000
            tick = start + 6 if delta else 0
            text += (f'gem-probe: sample={sample} start={start} done={start + duration} '
                     f'wake={start + duration - 1} wakes=1 irq_delta={delta} irq_tick={tick}\n')
        return text.encode() + IRQ_PASS + b'\n'
    good = evidence() if mode == 'irq-primary' else evidence(0, 15625)
    frames = [copy.copy(frame) for _ in range(33)]
    cases.note()
    validate_irq(good, frames, mode)
    wrong_bank = evidence(0, 15625) if mode == 'irq-primary' else evidence()
    bad = copy.deepcopy(frames)
    bad[0]['bytes'] = bad[0]['bytes'][:-2] + '00'
    candidates = [(IRQ_PASS, frames), (good.replace(IRQ_PASS, b''), frames),
                  (good + b'FAIL gem-probe: failure\n', frames),
                  (good, frames[:32]), (good, frames + frames[:1]), (good, bad),
                  (good.replace(b'frequency=1000000', b'frequency=0'), frames),
                  (good.replace(b'sample=31', b'sample=30'), frames),
                  (good.replace(b'done=100010', b'done=1').replace(b'done=115625', b'done=1'), frames),
                  (good.replace(b'wake=100009', b'wake=1').replace(b'wake=115624', b'wake=1'), frames),
                  (wrong_bank, frames)]
    for text, bodies in candidates:
        cases.note()
        try:
            validate_irq(text, bodies, mode)
        except RuntimeError:
            pass
        else:
            raise SystemExit('FAIL gem-tx fixture controls: invalid IRQ evidence accepted')
report_pass('gem-tx fixture controls', 'ownership and IRQ modes reject stale verdicts, missing or corrupt frames, wrong authorities, invalid timestamps and wrong-bank witnesses', cases=cases.ran)
