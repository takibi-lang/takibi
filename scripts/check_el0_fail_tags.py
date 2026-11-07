#!/usr/bin/env python3
"""An EL0 probe's el0_fail_at names its own object (GitHub issue #1412).

el0_fail_at(message, bs"<object>", src_loc()) prints srcloc[<object>]=..., and
scripts/decode_srcloc.py reads <object>.o.facts/srcloc.tsv to decode it. A
SrcLoc means something only against its own compile's table, so a tag that
names another object decodes to a wrong file:line without saying so. Each
kernel/arch/arm64/kernel/*.tkb that calls el0_fail_at must pass its own file
stem, which is its object's name in the Makefile; a planted mismatch is
refused by the in-script control.
"""
import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
CALL = re.compile(r'el0_fail_at\(\s*bs"(?:[^"\\]|\\.)*",\s*bs"([^"]*)"', re.S)


def problems(path: Path, text: str):
    return [f'{path.name}: el0_fail_at names "{tag}", not "{path.stem}"'
            for tag in CALL.findall(text) if tag != path.stem]


def main():
    bad = problems(Path('x_probe.tkb'), 'el0_fail_at(bs"m", bs"other", src_loc());')
    if not bad:
        print('FAIL el0-fail-tags: the planted mismatch was accepted', file=sys.stderr)
        return 1
    files = 0
    out = []
    for path in sorted((ROOT / 'kernel/arch/arm64/kernel').glob('*.tkb')):
        text = path.read_text()
        if CALL.search(text):
            files += 1
            out += problems(path, text)
    for line in out:
        print(f'FAIL el0-fail-tags: {line} (#1412)', file=sys.stderr)
    if out:
        return 1
    if files == 0:
        print('FAIL el0-fail-tags: no el0_fail_at caller found; the pattern stopped matching',
              file=sys.stderr)
        return 1
    report_pass('el0-fail-tags', 'each el0_fail_at caller names its own object', files=files)
    return 0


if __name__ == '__main__':
    sys.exit(main())
