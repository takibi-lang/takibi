#!/usr/bin/env python3
"""GitHub issue #1389: which check-lane members touch the land machinery.

A control that drives scripts/resource_lease.sh, vcpu_lease.sh, run_lane.sh,
lane_timing.sh or land.sh reads the land's environment: TAKIBI_LAND_ALLCHECK
(exported by land.sh around its allcheck, #1145) makes every simulated worker
skip the land wait, and TAKIBI_LANE_TIMING_DIR (#914) sends planted receipts
into the enclosing allcheck's summary. slowcheck_resource_lease.sh inherited
the first and passed only outside a land.

The member set is lexical and fail-closed: every scripts/check_* and
scripts/slowcheck_* file that names one of those scripts belongs, unless
EXEMPT gives the reason it only reads them as text. Both
check_land_env_isolation.py (each member clears the two variables itself)
and slowcheck_land_env_rerun.sh (each member runs a second time under a
simulated land) take the set from here.

    land_env_members.py     prints the member paths, one per line
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
MACHINERY = re.compile(r'\b(?:resource_lease|vcpu_lease|run_lane|lane_timing|land)\.sh\b')
VARIABLES = ('TAKIBI_LAND_ALLCHECK', 'TAKIBI_LANE_TIMING_DIR')

# Members that name a machinery script only as text they scan, never run.
EXEMPT = {
    'check_lane_budget.py': 'reads receipts and the Makefile; runs no machinery',
    'check_lease_before_deadline.py': 'lexical lint over runner sources',
    'check_nice_heavy.py': 'lexical lint over the Makefile',
    'check_qemu_vcpu_lease.py': 'lexical lint over runner sources',
    'check_workflow_shell.py': 'bash -n over workflow text',
    'check_land_env_isolation.py': 'this rule itself; reads members as text',
    'check_land_env_isolation_controls.py': 'plants text members in a temp tree',
    'slowcheck_land_env_rerun.sh': 'the rerun itself; its members clear the variables',
}


def candidates(scripts: Path):
    for path in sorted(scripts.iterdir()):
        if path.suffix in ('.py', '.sh') and path.name.startswith(('check_', 'slowcheck_')):
            yield path


def members(scripts: Path = ROOT / 'scripts', exempt=None):
    exempt = EXEMPT if exempt is None else exempt
    return [p for p in candidates(scripts)
            if p.name not in exempt and MACHINERY.search(p.read_text(errors='replace'))]


if __name__ == '__main__':
    for path in members():
        print(path)
