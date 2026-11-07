#!/usr/bin/env python3
"""GitHub issue #1389: a land-machinery control clears the land's variables.

slowcheck_resource_lease.sh inherited TAKIBI_LAND_ALLCHECK from the outer
land.sh, so every simulated worker skipped the land wait and the control
passed only outside a land (#1145); the same shape with
TAKIBI_LANE_TIMING_DIR had leaked planted receipts into allcheck (#914).

Every member scripts/land_env_members.py selects must clear both variables
for its whole run, at top level (column 0), so no later case inherits them:

    shell:   unset ... TAKIBI_LAND_ALLCHECK ... TAKIBI_LANE_TIMING_DIR ...
    python:  os.environ.pop('TAKIBI_LAND_ALLCHECK', None)

A case that wants a variable sets it on that one invocation. Per-call
`env -u` is not accepted: a lexical check cannot see that every call has it.
check_land_env_isolation_controls.py plants the failing shapes.
"""
from pathlib import Path
import re
import sys

from land_env_members import VARIABLES, members
from pass_line import report_pass


def cleared(path: Path, text: str):
    found = set()
    for line in text.splitlines():
        if path.suffix == '.sh':
            if line.startswith('unset '):
                found.update(v for v in VARIABLES if v in line.split()[1:])
        else:
            m = re.match(r"os\.environ\.pop\((['\"])(\w+)\1, None\)\s*(?:#.*)?$", line)
            if m and m.group(2) in VARIABLES:
                found.add(m.group(2))
    return found


def problems(paths):
    out = []
    for path in paths:
        missing = [v for v in VARIABLES if v not in cleared(path, path.read_text())]
        if missing:
            out.append(f'{path.name}: does not clear {", ".join(missing)} at top level')
    return out


def main():
    paths = members()
    bad = problems(paths)
    if not paths:
        print('FAIL land-env-isolation: no member found; the selector stopped matching', file=sys.stderr)
        return 1
    if bad:
        for line in bad:
            print(f'FAIL land-env-isolation: {line} (#1389)', file=sys.stderr)
        return 1
    report_pass('land-env-isolation', 'land-machinery members clear the land variables', members=len(paths))
    return 0


if __name__ == '__main__':
    sys.exit(main())
