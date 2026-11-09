#!/usr/bin/env python3
"""Controls for the secondary_tick_count layout check, in both directions."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from control_patch import replace_once
from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "check_secondary_tick_count_layout.py"
CASES = CaseCount()
SECONDARY = "kernel/arch/arm64/kernel/secondary.tkb"
ATOMIC = "kernel/lib/atomic_word.tkb"
READER = "scripts/gdb_tick_count.py"


def run(edit=None):
    """Copy the real three files, apply `edit` (path, old, new), run."""
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        for name in (SECONDARY, ATOMIC, READER, f"scripts/{CHECK}",
                     "scripts/pass_line.py", "scripts/source_scan.py",
                     "scripts/layout_text.py", "scripts/allowed_callers.tsv"):
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / name, root / name)
        if edit:
            path, old, new = edit
            text = (root / path).read_text()
            (root / path).write_text(replace_once(text, old, new, path))
        done = subprocess.run(
            [sys.executable, f"scripts/{CHECK}"], cwd=root,
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
        return done.returncode


def main():
    failures = []
    if run() != 0:
        failures.append("the real tree was refused")
    if run((SECONDARY, "secondary_tick_count: [AtomicWord; KERNEL_MAX_CORES]",
            "secondary_tick_count: [AtomicWord; KERNEL_MAX_CORES * 2]")) == 0:
        failures.append("a resized array passed")
    if run((SECONDARY, "secondary_tick_count: [AtomicWord;",
            "secondary_tick_count: [u32Word;")) == 0:
        failures.append("a changed element type passed")
    if run((ATOMIC, "private value: usize;", "private value: usize; pad: usize;")) == 0:
        failures.append("a two-field AtomicWord passed")
    if run((READER, "{8 * core}", "{4 * core}")) == 0:
        failures.append("a 4-byte stride in the reader passed")
    # Mutate the real prefix implementation, not a hand-written arithmetic
    # clone. Each shape changes admission or removes its atomic boundary.
    from check_secondary_tick_count_layout import ONLINE_CALLERS, online_problems
    from source_scan import code_only
    source = code_only((REPO / SECONDARY).read_text())
    callers = (REPO / "scripts/allowed_callers.tsv").read_text()
    for old, new in (
            ("kernel_online_cores: AtomicWord", "kernel_online_cores: io usize"),
            ("status == 0 &&", "status != 0 &&"),
            ("atomic_word_store(&kernel_online_cores, online + 1);", "kernel_online_cores = online + 1;"),
            ("core == online &&", "core >= online &&"),
            ("online < KERNEL_MAX_CORES", "online <= KERNEL_MAX_CORES"),
            ("online >= 1 &&", "online >= 0 &&"),
            ("online <= KERNEL_MAX_CORES", "online <= KERNEL_MAX_CORES + 1"),
            ("atomic_word_store(&kernel_online_cores, 1);", "atomic_word_store(&kernel_online_cores, 0);"),
            ("return 1;", "return 0;"),
            ("atomic_word_store(&kernel_online_cores, online + 1);", "atomic_word_store(&kernel_online_cores, online + 2);")):
        CASES.note()
        changed = replace_once(source, old, new, "online prefix control")
        if not online_problems(changed, callers):
            failures.append(f"online prefix mutation accepted: {old}")
    CASES.note()
    changed = source.replace("atomic_word_load(&kernel_online_cores)", "kernel_online_cores as usize")
    if not online_problems(changed, callers):
        failures.append("plain online prefix loads accepted")
    CASES.note()
    if not online_problems(source + "\nfn extra_writer() { atomic_word_store(&kernel_online_cores, 1); }", callers):
        failures.append("extra online prefix writer accepted")
    for helper, allowed in ONLINE_CALLERS.items():
        CASES.note()
        changed = callers.replace("\t" + helper + "\t" + allowed + "\t",
                                  "\t" + helper + "\t" + allowed + ",kernel/arch/arm64/kernel/secondary.tkb:kernel_idle_loop\t")
        if changed == callers or not online_problems(source, changed):
            failures.append(f"broadened boot caller row accepted: {helper}")
    if failures:
        for line in failures:
            print(f"FAIL secondary-tick-count-layout controls: {line}", file=sys.stderr)
        return 1
    report_pass("secondary-tick-count-layout controls",
                f"{CASES.ran} cases -- the real tree passes; a resized array, "
                "another element type, a wider AtomicWord and a 4-byte stride "
                "and online prefix predicate/access/caller mutations are refused", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
