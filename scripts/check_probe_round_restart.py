#!/usr/bin/env python3
"""Refuse invocation-local round batches in re-entered secondary probes.

The idle dispatcher may call an armed probe again after it returns. A local
0..<ROUNDS loop then restarts against the previous invocation's rendezvous
words, as the freelist probe did in CI. Finite phase rounds must instead use
shared completion state. This lexical check catches that observed shape,
not helper-hidden loops, numeric bounds, local while loops or arbitrary
phase-admission protocols; the actual two-core regression remains necessary.
"""

import re
import subprocess
import sys
from pathlib import Path

from check_model_function_map import function_body, masked_sources
from pass_line import report_pass

DRIVER = 'kernel/arch/arm64/kernel/secondary.tkb'
CALL = re.compile(r'\b(\w+_secondary_run)\s*\(\s*\)\s*;')
DEFINITION = re.compile(
    r'^(?:private\s+)?(?:inline\s+|noinline\s+)?fn\s+(\w+_secondary_run)\s*\(', re.M)
LOCAL_ROUNDS = re.compile(
    r'\bfor\s+\w+\s*:\s*usize\s+in\s+0\s*\.\.<\s*[A-Z][A-Z_0-9]*ROUNDS\s*\{')


def problems(sources):
    errors = []
    calls = sorted(set(CALL.findall(masked_sources(sources.get(DRIVER, '')))))
    if not calls:
        errors.append('no secondary probe entries found in the idle dispatcher')
    definitions = {}
    for path, source in sources.items():
        if '_secondary_run' not in source:
            continue
        for match in DEFINITION.finditer(masked_sources(source)):
            definitions.setdefault(match[1], []).append((path, source))
    for name in calls:
        candidates = definitions.get(name, [])
        if len(candidates) != 1:
            errors.append(f'{name}: expected one maintained body, found {len(candidates)}')
            continue
        path, source = candidates[0]
        body = function_body(name, source)
        if body is None:
            errors.append(f'{path}: {name}: cannot locate the body')
            continue
        for match in LOCAL_ROUNDS.finditer(masked_sources(body)):
            errors.append(f'{path}: {name}: invocation-local round batch restarts '
                          'on idle-loop re-entry; bound rounds by shared phase completion')
    return calls, errors


def tracked_sources():
    paths = subprocess.check_output(
        ['git', 'ls-files', 'kernel/**/*.tkb'], text=True).splitlines()
    return {path: Path(path).read_text(encoding='ascii') for path in paths}


def main(sources=None):
    calls, errors = problems(tracked_sources() if sources is None else sources)
    if errors:
        for error in errors:
            print(f'ERROR probe-round-restart: {error}')
        return 1
    report_pass('probe-round-restart',
                're-entered secondary probe entries have no invocation-local 0..<ROUNDS batch',
                entries=len(calls))
    return 0


if __name__ == '__main__':
    sys.exit(main())
