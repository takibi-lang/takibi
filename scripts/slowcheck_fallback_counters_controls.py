#!/usr/bin/env python3
"""Controls for the dead-slot fallback report check.

The check refuses two things, and both are shapes this tree has actually
held: a counter nothing reads (`process_image_root_fallback_uses`, until
issue #270 hit the case it counted) and a report that adds a line rather than
losing one, which no expected file misses. A control that only ran the
repository would prove neither, since the repository passes -- so each rule is
exercised with a controlled call graph or a planted defect in a tree copy.
The missing row and wholesale rename also test that the check still looks.
"""

from call_graph_table import COLUMNS, FORMAT, HEADER
from control_patch import replace_once
import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_fallback_counters.py"
GATE_FILE = "kernel/init/test_driver.tkb"
EXPECTED = "kernel/tests/common/views/process_lifecycle.expected"
POSITIVE = "resources: every pooled record resolved to the slot its handle named"


def run(root: pathlib.Path, facts=None):
    args = [sys.executable, str(root / CHECK)]
    if facts is not None:
        args.append(str(facts))
    finished = subprocess.run(
        args,
        cwd=root, capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


def planted(root: pathlib.Path, path: str, old: str, new: str) -> None:
    target = root / path
    text = target.read_text(encoding="ascii")
    target.write_text(replace_once(text, old, new), encoding="ascii")


def rename_all(root: pathlib.Path) -> None:
    """Rename every accessor, which is how a check quietly stops looking."""
    for path in sorted((root / "kernel").rglob("*.tkb")):
        text = path.read_text(encoding="ascii")
        renamed = (text.replace("_missing_uses(", "_missing_total(")
                       .replace("_fallback_uses(", "_fallback_total("))
        if renamed != text:
            path.write_text(renamed, encoding="ascii")


COUNTERS = (
    "process_image_record_missing_uses", "process_image_root_stale_fallback_uses",
    "address_space_backing_missing_uses", "unified_fd_record_missing_uses",
    "scheduled_process_record_missing_uses", "tcp_absent_fallback_uses",
)


def graph_case(name, callees, want=None):
    """Compare one controlled compiler table with the real source inventory."""
    CASES.note()
    row = dict.fromkeys(COLUMNS, "-")
    row.update(file=GATE_FILE, line="1", end_line="1",
               name="dead_slot_fallback_uses" if callees is not None else "unrelated_function",
               callees=",".join(callees) if callees else "-")
    text = f"{HEADER}{FORMAT}\n" + "\t".join(COLUMNS) + "\n"
    text += "\t".join(row.values()) + "\n"
    with tempfile.TemporaryDirectory() as directory:
        facts = pathlib.Path(directory) / "callgraph.tsv"
        facts.write_text(text, encoding="ascii")
        status, report = run(REPO, facts)
    expected_status = 0 if want is None else 1
    if status != expected_status or (want is not None and want not in report):
        return [f"{name}: exit {status}, report {report.strip()!r}"]
    return []


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def case(name, mutate, want) -> list[str]:
    """Copy the tree, plant one defect, and require the check to name it."""
    CASES.note()
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        # Only what the check reads, so a case costs a few files rather than
        # the whole repository.
        root.mkdir(parents=True)
        for part in ("scripts", "kernel"):
            shutil.copytree(REPO / part, root / part,
                            ignore=shutil.ignore_patterns(
                                "__pycache__", "build", "*.o", "*.elf",
                                "*.img", "*.apk", "busybox-*"))
        mutate(root)
        status, report = run(root)
        if status == 0:
            failures.append(f"{name}: the planted defect passed")
        elif want not in report:
            failures.append(f"{name}: reported {report.strip()!r}, which does "
                            f"not name {want!r}")
    return failures


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "6 counters inventoried" not in report:
        failures.append(f"the repository passed about an unexpected count: "
                        f"{report.strip()!r}")

    failures += graph_case("exact callee set", COUNTERS)
    failures += graph_case("missing direct edge", COUNTERS[:-1],
                           "does not sum tcp_absent_fallback_uses()")
    failures += graph_case("unexpected direct edge", (*COUNTERS, "unrelated_function"),
                           "calls unrelated_function()")
    failures += graph_case("missing sum row", None,
                           "expected one compiled dead_slot_fallback_uses(), found 0")

    failures += case(
        "report present only in a comment",
        lambda root: planted(root, GATE_FILE,
                             "    if (dead_slot_fallback_uses() == 0) {",
                             "    // if (dead_slot_fallback_uses() == 0) {"),
        "gates no positive report")

    failures += case(
        "advisory report",
        lambda root: planted(root, GATE_FILE,
                             "    if (dead_slot_fallback_uses() == 0) {",
                             "    if (dead_slot_fallback_uses() == 99) {"),
        "gates no positive report")

    failures += case(
        "line no view expects",
        lambda root: planted(root, EXPECTED, POSITIVE + "\n", ""),
        "so the boot prints it and nothing notices")

    failures += case(
        "every accessor renamed out from under it",
        rename_all,
        "no dead-slot fallback accessor found")

    for failure in failures:
        print(f"ERROR\tfallback-counters-controls: {failure}")
    if failures:
        print("FAIL fallback-counters controls: the check does not refuse a "
              "fallback that cannot fail a lane")
        return 1
    report_pass(
        "fallback-counters controls",
        "the exact callee set passes; missing and extra edges, a missing "
        "sum row, a commented or advisory report, an unexpected positive "
        "line and a wholesale rename are refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
