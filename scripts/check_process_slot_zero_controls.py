#!/usr/bin/env python3
"""Controls for the process-slot-zero check (GitHub issue #831).

The repository passes today, so a control that only ran the check would
prove nothing. Each rule is exercised against a synthetic kernel tree built
here, so a planted defect is the only difference between a pass and a fail.
The cases that matter most are the two #831 met as defects: a placement
branch that asks whether a slot is 0, and a per-process call handed slot 0.
"""

import pathlib
import sys
import tempfile

from pass_line import CaseCount, report_pass
import check_process_slot_zero as check

REPO = pathlib.Path(__file__).resolve().parent.parent
PROCESS = "kernel/kernel/process.tkb"
OTHER = "kernel/kernel/other.tkb"


def placement_tree(extra_allows=""):
    """Every PLACEMENT function, each with an innocent body."""
    lines = []
    for name in sorted(check.PLACEMENT):
        body = "    return 1;\n"
        if name == "kernel_process_cpu_allows_slot":
            body = extra_allows + "    return 1;\n"
        lines.append(f"fn {name}(slot: usize) -> usize {{\n{body}}}\n")
    return "".join(lines)


def build(root, process_text, other_text):
    (root / "kernel" / "kernel").mkdir(parents=True)
    (root / PROCESS).write_text(process_text, encoding="ascii")
    (root / OTHER).write_text(other_text, encoding="ascii")


def run(root):
    """The check's own verdict on a tree, in process: (status, report)."""
    found, files = check.problems(root)
    if found:
        return 1, "\n".join(found)
    return 0, f"no slot-0 branch ({files} files)"


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def case(name, process_text, other_text, want, should_fail=True):
    CASES.note()
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        build(root, process_text, other_text)
        status, report = run(root)
        if should_fail and status == 0:
            failures.append(f"{name}: the planted defect passed")
        elif not should_fail and status != 0:
            failures.append(f"{name}: a legitimate tree was refused: "
                            f"{report.strip()!r}")
        elif want and want not in report:
            failures.append(f"{name}: reported {report.strip()!r}, which "
                            f"does not name {want!r}")
    return failures


def main() -> int:
    failures = []
    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "no slot-0 branch" not in report:
        failures.append(f"the repository passed about something else: "
                        f"{report.strip()!r}")

    clean = placement_tree()
    failures += case("a clean tree", clean, "fn other() {}\n", "",
                     should_fail=False)
    failures += case(
        "a placement branch on slot 0, the shape #831 removed",
        placement_tree("    if (slot == 0) { return 0; }\n"),
        "fn other() {}\n", "branches on slot 0")
    failures += case(
        "the same branch written the other way round",
        placement_tree("    if (0 != slot) { return 0; }\n"),
        "fn other() {}\n", "branches on slot 0")
    failures += case(
        "a slot-0 sentinel outside placement is someone else's business",
        clean, "fn other(slot: usize) { if (slot == 0) { return; } }\n", "",
        should_fail=False)
    failures += case(
        "the static bootstrap's record named again",
        clean, "fn other() { let r = &scheduled_process_boot_record; }\n",
        "static bootstrap record")
    failures += case(
        "a per-process call handed slot 0",
        clean, "fn other() { match unified_fd_context_ensure(0) {} }\n",
        "unified_fd_context_ensure is given process slot 0")
    failures += case(
        "a word-keyed table setter handed slot 0",
        clean, "fn other() { scheduled_process_set_fd_context(0, a, g); }\n",
        "scheduled_process_set_fd_context is given process slot 0")
    failures += case(
        "a comment naming the old record is prose",
        clean, "// scheduled_process_boot_record went in #831\nfn other() {}\n",
        "", should_fail=False)
    failures += case(
        "a listed placement function that no longer exists",
        clean.replace("fn kernel_stack_bottom(", "fn kernel_stack_bottom_renamed("),
        "fn other() {}\n", "kernel_stack_bottom is listed")

    if failures:
        for failure in failures:
            print(f"ERROR\tprocess-slot-zero-controls: {failure}",
                  file=sys.stderr)
        print("FAIL process-slot-zero controls: a slot-0 process can come "
              "back without the check saying so", file=sys.stderr)
        return 1
    report_pass("process-slot-zero controls",
                "the repository passes; a placement branch on slot 0 either "
                "way round, the static record's name and a per-process call "
                "given slot 0 are refused; a sentinel elsewhere and prose "
                "are not; a stale placement list is refused",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
