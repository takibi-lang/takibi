#!/usr/bin/env python3
"""Controls for the lane artifact-root check.

The repository passes today, so a control that only ran the check would prove
nothing. Each rule is exercised against a planted copy of the tree it reads.

The case that matters is the first: a lane that keeps its own fixed
`_build/kernel-<lane>/` path. That is the state the repository was in before
GitHub issue #561, and nothing failed -- a repeat run still printed a rate and
still made a sample directory, and only the person who opened it afterwards
found the failing sample's capture had been replaced by the next sample's.
"""

from control_patch import replace_once
import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_lane_artifact_root.py"
LANE = "scripts/run_kernel_ddb_qemutest.sh"
REPEAT = "scripts/repeat_kernel_lane.sh"
MAKEFILE = "Makefile"


def run(root):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)], cwd=root,
        capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def case(name, plant, want, should_fail=True):
    """Copy what the check reads, plant one defect, require the verdict."""
    CASES.note()
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        (root / "scripts").mkdir(parents=True)
        for script in ("check_lane_artifact_root.py", "pass_line.py"):
            shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
        for path in sorted((REPO / "scripts").glob("run_kernel_*.sh")):
            shutil.copy(path, root / "scripts" / path.name)
        shutil.copy(REPO / REPEAT, root / REPEAT)
        shutil.copy(REPO / MAKEFILE, root / MAKEFILE)
        plant(root)
        status, report = run(root)
        if should_fail and status == 0:
            failures.append(f"{name}: the planted defect passed")
        elif not should_fail and status != 0:
            failures.append(f"{name}: a legitimate tree was refused: "
                            f"{report.strip()!r}")
        elif want and want not in report:
            failures.append(f"{name}: reported {report.strip()!r}, which does "
                            f"not name {want!r}")
    return failures


def edit(relative, old, new):
    def plant(root):
        target = root / relative
        text = target.read_text(encoding="ascii")
        assert text.count(old) == 1, f"{old!r} is not a unique anchor"
        target.write_text(replace_once(text, old, new), encoding="ascii")
    return plant


def add_lane(name, body):
    """A new lane runner, the way someone adding a lane would write one."""
    def plant(root):
        (root / "scripts" / name).write_text(body, encoding="ascii")
    return plant


PEER_HEAD = ('#!/usr/bin/env bash\nset -euo pipefail\n'
             'ARTIFACT_DIR="${KERNEL_QEMU_PEER_ARTIFACT_DIR:-'
             '${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}'
             '/kernel-peer-qemu}"\n'
             'mkdir -p "$ARTIFACT_DIR"\n')
ARCHIVING_TRAP = ('archive_on_failure() {\n'
                  '    local status=$?\n'
                  '    bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" '
                  '"$ARTIFACT_DIR" \\\n'
                  '        "$REPO_ROOT/_build/kernel-peer-qemu-failures" late\n'
                  '    return "$status"\n'
                  '}\n'
                  'trap archive_on_failure EXIT\n')

ROOTED = ('ARTIFACT_DIR="${KERNEL_QEMU_DDB_ARTIFACT_DIR:-'
          '${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-ddb-qemu}"')


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "19 lane runner(s)" not in report:
        failures.append(f"the repository passed about an unexpected number of "
                        f"lanes: {report.strip()!r}")

    # The pre-#561 shape: a lane keeping its own fixed directory.
    failures += case(
        "a lane that keeps its own fixed directory",
        edit(LANE, ROOTED,
             'ARTIFACT_DIR="${KERNEL_QEMU_DDB_ARTIFACT_DIR:-'
             '$REPO_ROOT/_build/kernel-ddb-qemu}"'),
        "rather than")

    # A new lane added without an artifact directory this check can see.
    failures += case(
        "a new lane with no readable artifact directory",
        add_lane("run_kernel_peer_qemutest.sh",
                 '#!/usr/bin/env bash\nset -euo pipefail\n'
                 'OUT="$REPO_ROOT/_build/kernel-peer-qemu"\nmkdir -p "$OUT"\n'),
        "defines no ARTIFACT_DIR")

    # A new lane whose ARTIFACT_DIR is written in a shape the check cannot
    # read. Refused rather than skipped: an unreadable assignment is how the
    # rule would quietly stop applying to one lane.
    failures += case(
        "a lane whose ARTIFACT_DIR cannot be read",
        add_lane("run_kernel_peer_qemutest.sh",
                 '#!/usr/bin/env bash\nset -euo pipefail\n'
                 'ARTIFACT_DIR=$REPO_ROOT/_build/kernel-peer-qemu\n'),
        "cannot read")

    # A second directory beside the artifact one, which is how a lane leaks
    # evidence past the root without touching ARTIFACT_DIR at all.
    failures += case(
        "a second capture directory beside the artifact one",
        edit(LANE, 'mkdir -p "$ARTIFACT_DIR"',
             'mkdir -p "$ARTIFACT_DIR" "$REPO_ROOT/_build/kernel-ddb-traces"'),
        "kernel-ddb-traces")

    # An archive root is allowed only for a lane that actually archives.
    failures += case(
        "an archive root in a lane that archives nothing",
        # A planted lane, since every existing lane archives (#877).
        add_lane("run_kernel_peer_qemutest.sh", PEER_HEAD +
                 'mkdir -p "$REPO_ROOT/_build/kernel-peer-qemu-failures"\n'),
        "nothing archives into")

    # The other direction, so the archive allowance is a classification
    # rather than a hole: a NEW lane that hangs off the root and archives
    # into its own `-failures` path is accepted. Planted rather than read off
    # the existing oops lane, because what is being checked is that the rule
    # generalizes to the next lane somebody writes.
    failures += case(
        "a new archiving lane that hangs off the root",
        add_lane("run_kernel_peer_qemutest.sh",
                 '#!/usr/bin/env bash\nset -euo pipefail\n'
                 'ARTIFACT_DIR="${KERNEL_QEMU_PEER_ARTIFACT_DIR:-'
                 '${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}'
                 '/kernel-peer-qemu}"\n'
                 'mkdir -p "$ARTIFACT_DIR"\n' + ARCHIVING_TRAP),
        "", should_fail=False)

    # GitHub issue #877: a lane with no failure archive. The DDB lane lost
    # its failing capture to a passing rerun this way; planted by removing
    # the profile lane's archiving trap, the shape it had before #877.
    failures += case(
        "a lane that never archives a failing capture",
        edit("scripts/run_kernel_profile_qemutest.sh",
             "trap archive_on_failure EXIT\n", ""),
        "never calls archive_kernel_failure.sh from an EXIT trap")

    # The archiver called, but from one failure branch rather than from an
    # EXIT trap: `set -e` and every other exit skip it.
    failures += case(
        "an archive call outside any EXIT trap",
        add_lane("run_kernel_peer_qemutest.sh", PEER_HEAD +
                 'false || bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" '
                 '"$ARTIFACT_DIR" "$REPO_ROOT/_build/kernel-peer-qemu-failures" '
                 'late\n'),
        "never calls archive_kernel_failure.sh from an EXIT trap")

    # A later EXIT trap that replaces the archiving one.
    failures += case(
        "a later EXIT trap that replaces the archiving one",
        add_lane("run_kernel_peer_qemutest.sh", PEER_HEAD + ARCHIVING_TRAP +
                 "trap 'kill $QEMU_PID' EXIT\n"),
        "does not call archive_kernel_failure.sh")

    # The pre-#877 alloc-rollback shape: the trap cleared once QEMU stopped,
    # so every verdict check after it failed with no archive.
    failures += case(
        "an archiving EXIT trap cleared before the checks",
        add_lane("run_kernel_peer_qemutest.sh", PEER_HEAD + ARCHIVING_TRAP +
                 "trap - EXIT INT TERM HUP\ngrep -q PASS uart.log\n"),
        "clears its EXIT trap and never re-arms")

    # A clear followed by a re-armed archive (the RPi5 runner's shape), or by
    # nothing at all (the RPi5 DDB runner's), is legitimate.
    failures += case(
        "a cleared trap that is re-armed",
        add_lane("run_kernel_peer_qemutest.sh", PEER_HEAD + ARCHIVING_TRAP +
                 "trap - EXIT INT TERM HUP\n" + ARCHIVING_TRAP +
                 "grep -q PASS uart.log\n"),
        "", should_fail=False)
    failures += case(
        "a cleared trap at the very end",
        add_lane("run_kernel_peer_qemutest.sh", PEER_HEAD + ARCHIVING_TRAP +
                 "trap - EXIT INT TERM HUP\n# done\n"),
        "", should_fail=False)

    # The Makefile's variant overrides bypass the root.
    failures += case(
        "a Makefile variant override outside the root",
        edit(MAKEFILE,
             'KERNEL_QEMU_DDB_ARTIFACT_DIR="$(TAKIBI_LANE_ARTIFACT_ROOT)/kernel-ddb-qemu-software"',
             'KERNEL_QEMU_DDB_ARTIFACT_DIR="$(CURDIR)/_build/kernel-ddb-qemu-software"'),
        "keeps its fixed directory under a repeat")

    # `:=` instead of `?=` silently ignores an exported root, which is the
    # one make detail that makes the whole mechanism inert.
    failures += case(
        "a root the environment cannot override",
        edit(MAKEFILE, "TAKIBI_LANE_ARTIFACT_ROOT ?= $(CURDIR)/_build",
             "TAKIBI_LANE_ARTIFACT_ROOT := $(CURDIR)/_build"),
        "an exported root would not win")

    # And the repeat runner forgetting to move it per sample.
    failures += case(
        "the repeat runner no longer moving the root",
        edit(REPEAT, '"TAKIBI_LANE_ARTIFACT_ROOT=$sample_dir"',
             '"KERNEL_QEMU_HWTEST_ARTIFACT_DIR=$sample_dir"'),
        "no longer points TAKIBI_LANE_ARTIFACT_ROOT")

    for failure in failures:
        print(f"ERROR\tlane-artifact-root-controls: {failure}")
    if failures:
        print("FAIL lane-artifact-root controls: a lane can still escape the "
              "shared artifact root")
        return 1
    report_pass(
        "lane-artifact-root controls",
        "the repository passes, an archiving lane keeps its archive root, "
        "and a fixed lane directory, a new lane with no readable one, an "
        "unreadable assignment, a second capture directory, an archive root "
        "in a lane that archives nothing, a Makefile variant outside the "
        "root, a root the environment cannot override, a repeat runner "
        "that stops moving it, a lane that never archives, an archive call "
        "outside an EXIT trap, a later EXIT trap that replaces it, and a "
        "cleared one never re-armed are each refused, while a re-armed or "
        "final clear passes",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
