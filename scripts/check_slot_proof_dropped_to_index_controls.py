#!/usr/bin/env python3
"""Controls for the slot-proof-to-index check.

The repository passes today, so a control that only ran the check would prove
nothing. Each rule is exercised against a synthetic kernel tree, built here:
what is under test is the rules, and a minimal tree makes each planted defect
the only difference between a pass and a fail.

The case that matters is the first: a NEW function that drops a slot view and
keeps only the address. That is GitHub issue #569's shape, and it is silent --
the code compiles, the walk behaves correctly, and only a counter somewhere
else eventually calls it a defect.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_slot_proof_dropped_to_index.py"
SOURCE = "kernel/kernel/synthetic.tkb"
DEFINING = "kernel/lib/intrusive_pool.tkb"

CARRIES = '''private fn synthetic_handle_of_slot(slot: usize) -> ProcessHandle {
    match intrusive_pool_probe_slot(&pool, slot) {
        IntrusiveSlotProbe::NoPayload => { return absent; }
        IntrusiveSlotProbe::Live(slot_view) => {
            let generation: usize = intrusive_view_generation(slot_view);
            intrusive_view_drop(slot_view);
            return live;
        }
    }
}
'''

INDEX_ONLY = '''private fn synthetic_next_live_slot(slot: usize) -> usize {
    match intrusive_pool_probe_slot(&pool, slot) {
        IntrusiveSlotProbe::NoPayload => { return 0; }
        IntrusiveSlotProbe::Live(slot_view) => {
            intrusive_view_drop(slot_view);
            return slot;
        }
    }
}
'''

# The two the repository declares, reproduced so a synthetic tree can carry
# the same declarations the real one does.
DECLARED = '''private fn scheduled_process_live_pool_slot_from(cursor: usize) -> usize {
    match intrusive_pool_probe_slot(&pool, cursor) {
        IntrusiveSlotProbe::NoPayload => { return 0; }
        IntrusiveSlotProbe::Live(slot_view) => {
            intrusive_view_drop(slot_view);
            return cursor;
        }
    }
}

fn scheduled_process_slot_valid(slot: usize) -> bool {
    match intrusive_pool_probe_slot(&pool, slot) {
        IntrusiveSlotProbe::NoPayload => { return false; }
        IntrusiveSlotProbe::Live(slot_view) => {
            intrusive_view_drop(slot_view);
            return true;
        }
    }
}
'''


def build(root, body):
    (root / "scripts").mkdir(parents=True)
    for script in ("check_slot_proof_dropped_to_index.py", "pass_line.py"):
        shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
    (root / "kernel" / "kernel").mkdir(parents=True)
    (root / "kernel" / "lib").mkdir(parents=True)
    # The defining file is skipped by name, so its content only has to exist.
    (root / DEFINING).write_text(
        "fn intrusive_view_drop(slot_view: sink IntrusiveSlotView) {}\n",
        encoding="ascii")
    (root / SOURCE).write_text(DECLARED + body, encoding="ascii")


def run(root):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)], cwd=root,
        capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def case(name, body, want, should_fail=True):
    CASES.note()
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        build(root, body)
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


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "drop a slot view" not in report:
        failures.append(f"the repository passed about something else: "
                        f"{report.strip()!r}")

    # GitHub issue #569's shape, added fresh.
    failures += case(
        "a new function that drops the proof to a bare index",
        INDEX_ONLY, "keeps no generation")

    # The same function written so its answer stays checkable is accepted,
    # which is what makes this a rule rather than a ban on dropping.
    failures += case(
        "a new function that carries the generation forward",
        CARRIES, "", should_fail=False)

    # A prose mention is not a call, in either direction.
    failures += case(
        "prose naming the drop",
        "// intrusive_view_drop( is named here in a comment\n",
        "", should_fail=False)

    # A declaration is a claim, so it has to keep describing something. Both
    # directions: the function stopped dropping, and the function started
    # carrying a generation and no longer needs the exemption.
    for name, replaced, want in (
        ("a declared function that stopped dropping a view",
         DECLARED.replace("            intrusive_view_drop(slot_view);\n"
                          "            return cursor;",
                          "            return cursor;"),
         "no longer drops one"),
        ("a declared function that now carries a generation",
         DECLARED.replace("        IntrusiveSlotProbe::Live(slot_view) => {\n"
                          "            intrusive_view_drop(slot_view);\n"
                          "            return cursor;",
                          "        IntrusiveSlotProbe::Live(slot_view) => {\n"
                          "            let generation: usize = "
                          "intrusive_view_generation(slot_view);\n"
                          "            intrusive_view_drop(slot_view);\n"
                          "            return cursor;"),
         "now keeps one"),
    ):
        CASES.note()
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw) / "tree"
            build(root, "")
            (root / SOURCE).write_text(replaced, encoding="ascii")
            status, report = run(root)
            if status == 0:
                failures.append(f"{name}: the planted defect passed")
            elif want not in report:
                failures.append(f"{name}: reported {report.strip()!r}, which "
                                f"does not name {want!r}")

    for failure in failures:
        print(f"ERROR\tslot-proof-to-index-controls: {failure}")
    if failures:
        print("FAIL slot-proof-to-index controls: a slot view can still be "
              "dropped to an index without anyone deciding to")
        return 1
    report_pass(
        "slot-proof-to-index controls",
        "the repository passes, a new dropper that carries the generation is "
        "accepted and one that keeps only the index is refused, prose is not "
        "a call, and a declaration whose function stopped dropping or started "
        "carrying a generation is refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
