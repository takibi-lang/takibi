#!/usr/bin/env python3
"""Controls for check_fast_gate_no_spawn.py (#808)."""

from check_fast_gate_no_spawn import REVIEWED, members, problems
from pass_line import CaseCount, report_pass


def main() -> int:
    cases = CaseCount()
    tree = members()
    assert not problems(tree), problems(tree)
    failing = {
        # The #808 shape: a control that runs the check under Python per case.
        "sys.executable child": "import subprocess, sys\n"
                                "subprocess.run([sys.executable, 'x.py'])\n",
        "compiler child": "import subprocess\nsubprocess.check_output(['dune', 'exec', 'x'])\n",
        "computed argv": "import subprocess\nsubprocess.Popen(argv)\n",
        "os.system": "import os\nos.system('make x')\n",
        "os.execv": "import os\nos.execv('/bin/sh', ['sh'])\n",
    }
    for name, text in failing.items():
        cases.note()
        assert problems({**tree, "check_zz_controls.py": text}), name
    passing = {
        "git ls-files": "import subprocess\nsubprocess.run(['git', 'ls-files'])\n",
        "spawn named in a string": "TEXT = 'subprocess.run([sys.executable])'\n",
    }
    for name, text in passing.items():
        cases.note()
        assert not problems({**tree, "check_zz.py": text}), name
    cases.note()
    assert problems(tree, {**REVIEWED, "check_agents_paths.py": "x"}), "stale: git only"
    cases.note()
    assert problems(tree, {**REVIEWED, "check_gone.py": "x"}), "stale: absent"
    report_pass("fast-gate-no-spawn controls",
                f"production passes and {cases.ran} spawning, git-only and stale "
                f"shapes behave as specified", controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
