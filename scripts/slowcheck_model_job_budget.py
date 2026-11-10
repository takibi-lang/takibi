#!/usr/bin/env python3
"""Exercise allcheck's real model-job default and recursive make propagation.

Only probe recipes run: the production target-specific variable and the two
recursive command texts are retained, while their child makefile reports its
inputs. No aggregate, compiler, solver, lease or guest is started.
"""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parents[1]
MAKEFILE = ROOT / "Makefile"


def main() -> int:
    source = MAKEFILE.read_text()
    found = re.search(r"resource_lease_run_suite allcheck bash -c \\\n\s*'([^']+)'", source)
    if found is None:
        print("FAIL model-job-budget: cannot locate allcheck's recursive commands")
        return 1
    command = found.group(1)
    if command.count("$(MAKE)") != 2:
        print("FAIL model-job-budget: allcheck must retain both recursive makes")
        return 1
    count = CaseCount()
    with tempfile.TemporaryDirectory(prefix="takibi-model-budget-") as tmp:
        scratch = Path(tmp)
        bindir = scratch / "bin"
        bindir.mkdir()
        nproc = bindir / "nproc"
        nproc.write_text('#!/bin/sh\nprintf "%s\\n" "$CONTROL_CPUS"\n')
        nproc.chmod(0o755)
        probe = scratch / "probe.py"
        probe.write_text(
            'import os,sys\n'
            'raw=os.environ.get("MODELCHECK_JOBS", "<unset>")\n'
            'effective=raw if raw not in ("", "<unset>") else os.environ["CONTROL_CPUS"]\n'
            'print("BUDGET",sys.argv[1],raw or "<empty>",effective)\n')
        child = scratch / "child.mk"
        goals = "allcheck-prebuild langcheck slowcheck test linuxcheck modelcheck kernelcheck"
        child.write_text(f".PHONY: {goals}\n{goals}:\n\t@python3 {probe} $@\n")
        overlay = scratch / "probe.mk"
        # These override recipes only, retaining production target-specific
        # variables. The allcheck body is the actual production command text.
        overlay.write_text(
            "allcheck:\n\t@" + command + "\n"
            "modelcheck:\n\t@$(MAKE) modelcheck\n"
            "cicheck-models:\n\t@$(MAKE) $(cicheck_lanes_$@)\n")
        base_env = dict(os.environ, CONTROL_CPUS="24", TAKIBI_JOBS="1")
        for name in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEFILES", "MODELCHECK_JOBS",
                     "TAKIBI_LANE_TIMING_DIR", "TAKIBI_CPU_LANE"):
            base_env.pop(name, None)
        base_env["PATH"] = str(bindir) + os.pathsep + base_env["PATH"]

        def case(goal: str, cpus: int, supplied: str | None,
                 cli: str | None, expected: str) -> bool:
            env = dict(base_env, CONTROL_CPUS=str(cpus))
            if supplied is not None:
                env["MODELCHECK_JOBS"] = supplied
            args = ["make", "-s", "-f", str(MAKEFILE), "-f", str(overlay),
                    "-o", "build", "-o", "litmuscheck", "-o", "range-obligation-control",
                    "MAKE=make -s -f " + str(child), goal]
            if cli is not None:
                args.append("MODELCHECK_JOBS=" + cli)
            result = subprocess.run(args, cwd=ROOT, env=env, text=True,
                                    capture_output=True)
            rows = [row.split() for row in result.stdout.splitlines()
                    if row.startswith("BUDGET ")]
            expected_goals = goals.split() if goal == "allcheck" else ["modelcheck"]
            observed = [(row[1], row[3]) for row in rows if len(row) == 4]
            wanted = [(name, expected) for name in expected_goals]
            if result.returncode != 0 or observed != wanted:
                print(f"FAIL model-job-budget: {goal} cores={cpus} env={supplied!r} "
                      f"CLI={cli!r}: expected {wanted}, observed {observed}, "
                      f"exit {result.returncode}\n{result.stdout}\n{result.stderr}")
                return False
            # Effective defaults alone cannot show the value was exported.
            if goal == "allcheck" and any(row[2] != expected for row in rows):
                print("FAIL model-job-budget: recursive allcheck value was not exported")
                return False
            count.note()
            return True

        for cpus, supplied, cli, expected in [
                (24, None, None, "16"), (4, None, None, "4"), (16, None, None, "16"),
                (24, "6", None, "6"), (24, None, "7", "7"), (24, "6", "7", "7"),
                (24, "", None, "16"), (24, None, "", "16")]:
            if not case("allcheck", cpus, supplied, cli, expected):
                return 1
        for goal in ("modelcheck", "cicheck-models"):
            for cpus, supplied, cli, expected in [
                    (24, None, None, "24"), (4, None, None, "4"),
                    (24, "6", None, "6"), (24, None, "7", "7"),
                    (24, "", None, "24"), (24, None, "", "24")]:
                if not case(goal, cpus, supplied, cli, expected):
                    return 1
    report_pass("model-job-budget",
                "allcheck bounds its default and propagates both recursive values; "
                "explicit overrides and standalone/CI defaults survive",
                scenarios=count.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
