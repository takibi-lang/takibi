#!/usr/bin/env python3
"""Planted controls for check_land_env_isolation.py (GitHub issue #1389)."""
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
from check_land_env_isolation import problems
from land_env_members import members
from pass_line import CaseCount, report_pass

CASES = CaseCount()

GOOD_SH = '#!/bin/bash\nunset TAKIBI_LANE_TIMING_DIR TAKIBI_LAND_ALLCHECK\nbash scripts/run_lane.sh x true\n'
GOOD_PY = ("import os\nos.environ.pop('TAKIBI_LAND_ALLCHECK', None)\n"
           "os.environ.pop(\"TAKIBI_LANE_TIMING_DIR\", None)\n# scripts/land.sh\n")
BAD = {
    # The #1145 shape: TAKIBI_LAND_ALLCHECK inherited.
    'slowcheck_inherits_land.sh': '#!/bin/bash\nunset TAKIBI_LANE_TIMING_DIR\nbash scripts/resource_lease.sh\n',
    # The #914 shape: receipts sent to the enclosing allcheck.
    'check_inherits_timing_controls.py': "import os\nos.environ.pop('TAKIBI_LAND_ALLCHECK', None)\n# lane_timing.sh\n",
    # Indented: clears only inside one function, later cases inherit.
    'slowcheck_indented.sh': '#!/bin/bash\nf() {\n    unset TAKIBI_LAND_ALLCHECK TAKIBI_LANE_TIMING_DIR\n}\n# vcpu_lease.sh\n',
    # Named in a comment only, not cleared.
    'slowcheck_comment.sh': '#!/bin/bash\n# unset TAKIBI_LAND_ALLCHECK TAKIBI_LANE_TIMING_DIR\n# land.sh\n',
    # A per-call env -u is not accepted.
    'slowcheck_env_u.sh': '#!/bin/bash\nenv -u TAKIBI_LAND_ALLCHECK -u TAKIBI_LANE_TIMING_DIR bash scripts/land.sh\n',
}


def case(name, text, want_bad):
    CASES.note()
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / name
        path.write_text(text)
        assert members(Path(tmp), exempt={}) == [path], f'{name} not selected'
        got = bool(problems([path]))
        assert got == want_bad, f'{name}: expected {"refusal" if want_bad else "acceptance"}'


def main():
    case('slowcheck_good.sh', GOOD_SH, False)
    case('check_good_controls.py', GOOD_PY, False)
    for name, text in BAD.items():
        case(name, text, True)
    # Selector: a member naming no machinery script is not selected, and a
    # file outside the two lane prefixes never is.
    with tempfile.TemporaryDirectory() as tmp:
        CASES.note()
        (Path(tmp) / 'check_other.py').write_text('print(1)\n')
        (Path(tmp) / 'helper.sh').write_text('bash scripts/land.sh\n')
        assert members(Path(tmp), exempt={}) == [], 'selector picked a non-member'
    report_pass('land-env-isolation-controls', 'planted shapes refused, good shapes accepted',
                cases=CASES.ran)
    return 0


if __name__ == '__main__':
    sys.exit(main())
