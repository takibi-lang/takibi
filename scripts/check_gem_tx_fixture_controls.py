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
    text += b'gem-tx fixture: keep refused at the reserve ok\n'
    text += PASS + b'\n'
    frame = {'bytes': (bytes.fromhex('ffffffffffff') + BOARD + bytes.fromhex('88b5') + PAYLOAD).hex()}
    count = 6 if mode == 'window-closed' else 7
    if mode == 'window-closed':
        text += b'gem-tx fixture: halt tsr=33 ncr=0\n'
        bars = (b'gem-tx fixture: inbound bar 1 lo=4294963228 remap=1245185\n'
                b'gem-tx fixture: inbound bar 2 lo=6291459 remap=6291457\n')
        for bar in range(3, 11):
            bars += b'gem-tx fixture: inbound bar %d lo=0 remap=0\n' % bar
        inside = b'gem-tx fixture: rx stage inside frames=124 own=1 rsr=3 isr=0 changed=8 word1=1085004156508283543\n'
        outside = b'gem-tx fixture: rx stage outside frames=123 own=1 rsr=3 isr=0 changed=0 word1=11936128518282651045\n'
        text += bars + inside + outside
    frames = [copy.copy(frame) for _ in range(count)]
    cases.note()
    validate(text, frames, mode)
    bad = copy.deepcopy(frames)
    bad[0]['bytes'] = bad[0]['bytes'][:-2] + '00'
    wrong_authority = text.replace(b'authority ' + last.encode(), b'authority wrong')
    if mode == 'window-closed':
        # GitHub issue #1254: each stands for a board that defeats the arena,
        # or for evidence that could not have shown it.
        for before, after in ((b'bar 3 lo=0 remap=0', b'bar 3 lo=3 remap=0'),
                              (b'bar 10 lo=0 remap=0', b'bar 10 lo=0 remap=1'),
                              (b'gem-tx fixture: inbound bar 7 lo=0 remap=0\n', b''),
                              (b'bar 2 lo=6291459', b'bar 2 lo=0'),
                              (b'bar 2 lo=6291459', b'bar 2 lo=7340035'),
                              (b'bar 1 lo=4294963228 remap=1245185', b'bar 1 lo=0 remap=0'),
                              (b'outside frames=123 own=1 rsr=3 isr=0 changed=0', b'outside frames=123 own=1 rsr=3 isr=0 changed=8'),
                              (b'outside frames=123', b'outside frames=0'),
                              (b'inside frames=124', b'inside frames=0'),
                              (b'inside frames=124 own=1', b'inside frames=124 own=0'),
                              (b'changed=8', b'changed=0'),
                              (b'word1=1085004156508283543', b'word1=11936128518282651045'),
                              (outside, b''), (inside, b'')):
            if before not in text:
                raise SystemExit(f'FAIL gem-tx fixture controls: stale anchor {before!r}')
            cases.note()
            try:
                validate(text.replace(before, after), frames, mode)
            except RuntimeError:
                pass
            else:
                raise SystemExit(f'FAIL gem-tx fixture controls: accepted {after!r}')
    for candidate, bodies in ((PASS, frames), (text.replace(PASS, b''), frames),
                              (text + b'FAIL gem-tx: failure\n', frames),
                              (text.replace(b'keep refused at the reserve ok', b''), frames),
                              (text, frames[:count - 1]), (text, frames + frames[:1]),
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
