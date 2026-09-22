#!/usr/bin/env python3
"""Controls for the pool clear-before-stamp check.

The repository passes today, so a control that only ran the check would prove
nothing. Each case is a synthetic pool file with one deliberate difference,
which makes the planted defect the only reason a run can fail.

The case that matters is the second: the clear moved back after the stamp.
That is GitHub issue #514's order, and it is silent -- every lane stays green,
because seeing the window needs a second core reading the pool without its
lock.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_pool_zero_before_stamp.py"
POOL = "kernel/lib/intrusive_pool.tkb"

CORRECT = '''private fn intrusive_pool_insert_unchecked(T: type, pool: &mut P,
                                           guard: borrow G,
                                           zero_payload: bool)
        -> R !{unsafe} {
    header.free_head = *intrusive_slot_link_at(pool, slot_address);
    let generation: usize = pool.next_generation;
    if (zero_payload) {
        for i: isize in 0..<span { bytes[i] = 0; }
    }
    slot.generation = generation;
    return R::Allocated(owner);
}

fn intrusive_pool_after(pool: &mut P) -> usize {
    slot.generation = 0;
    return 0;
}
'''

STAMP_FIRST = CORRECT.replace(
    '''    if (zero_payload) {
        for i: isize in 0..<span { bytes[i] = 0; }
    }
    slot.generation = generation;''',
    '''    slot.generation = generation;
    if (zero_payload) {
        for i: isize in 0..<span { bytes[i] = 0; }
    }''')

NO_CLEAR = CORRECT.replace(
    '''    if (zero_payload) {
        for i: isize in 0..<span { bytes[i] = 0; }
    }
''', "")

NO_STAMP = CORRECT.replace("    slot.generation = generation;\n", "")

RENAMED = CORRECT.replace("intrusive_pool_insert_unchecked",
                          "intrusive_pool_take_unchecked")

# The check must read only insert_unchecked's own body. A later function whose
# text would satisfy the order on its own must not rescue a broken one, and a
# later function that breaks it must not fail a correct one.
TRAILING_CLEAR = STAMP_FIRST + '''
private fn intrusive_pool_later(pool: &mut P) -> usize {
    if (zero_payload) {
        for i: isize in 0..<span { bytes[i] = 0; }
    }
    slot.generation = generation;
    return 0;
}
'''


def build(root, body):
    (root / "scripts").mkdir(parents=True)
    for script in ("check_pool_zero_before_stamp.py", "pass_line.py"):
        shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
    (root / "kernel" / "lib").mkdir(parents=True)
    (root / POOL).write_text(body, encoding="ascii")


def run(root):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)], cwd=root,
        capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def case(name, body, expect_fail, wanted=""):
    CASES.note()
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        build(root, body)
        status, report = run(root)
        if expect_fail and status == 0:
            failures.append(f"{name}: the planted defect passed")
        if not expect_fail and status != 0:
            failures.append(f"{name}: a legitimate tree was refused: {report}")
        if expect_fail and wanted and wanted not in report:
            failures.append(
                f"{name}: refused, but did not say {wanted!r}: {report}")
    return failures


def main():
    failures = []
    failures += case("correct order", CORRECT, False)
    failures += case("stamp before clear", STAMP_FIRST, True,
                     "stamps the generation before clearing")
    failures += case("no clear at all", NO_CLEAR, True,
                     "nothing clears a slot's storage")
    failures += case("no stamp at all", NO_STAMP, True,
                     "cannot tell where the slot starts answering Live")
    failures += case("function renamed away", RENAMED, True,
                     "rename it here too rather than deleting the check")
    failures += case("a later function does not rescue a broken one",
                     TRAILING_CLEAR, True,
                     "stamps the generation before clearing")

    with tempfile.TemporaryDirectory() as raw:
        CASES.note()
        root = pathlib.Path(raw) / "tree"
        build(root, CORRECT)
        (root / POOL).unlink()
        status, report = run(root)
        if status == 0:
            failures.append("missing pool file: a vanished pool passed")

    if failures:
        for line in failures:
            print(f"FAIL pool-zero-before-stamp controls: {line}",
                  file=sys.stderr)
        return 1
    report_pass(
        "pool-zero-before-stamp controls",
        f"{CASES.ran} cases -- the repository's order passes; the stamp "
        "moved ahead of the clear, a missing clear, a missing stamp, a "
        "renamed function, a later function whose own order is right, and a "
        "vanished pool file are each refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
