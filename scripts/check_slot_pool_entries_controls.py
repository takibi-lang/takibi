#!/usr/bin/env python3
"""Exercise the actual slot checker on direct calls and escaped callbacks.

The temporary source is a host-check fixture, never an executed kernel.
An optional checker path permits the same controls to reject an old checker.
Every negative requires both nonzero exit and its particular diagnostic.
"""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import sys
import tempfile

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
ACQUIRE = "exec_window_slot_acquire"
BASE = """linear struct ExecWindowSlot[unit: usize] { private index: usize; }
private fn exec_window_slot_acquire() -> ExecWindowSlot[0] {
    let mut slot: ExecWindowSlot[0] = { 0 }; return slot;
}
private fn exec_window_slot_release(slot: sink ExecWindowSlot[0]) {}
private fn entry() {
    let slot = exec_window_slot_acquire();
    exec_window_slot_release(slot);
}
fn kernel_process_block_control() {}
"""


def load_checker(path):
    spec = importlib.util.spec_from_file_location("slot_checker", path)
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    return checker


def invoke(checker, root):
    """Call the real main and observe its real exit branch without waiting.

    The original built-in controls keep their production pool configuration;
    only the temporary one-pool source tree uses the holders fixture rule.
    Unexpected exceptions propagate instead of becoming intended rejections.
    """
    original_root = checker.ROOT
    original_pools = checker.POOLS
    original_controls = checker.controls
    fixture_pools = [("kernel/pool.tkb", ACQUIRE, "ExecWindowSlot", "holders")]

    def controls():
        checker.POOLS = original_pools
        try:
            original_controls()
        finally:
            checker.POOLS = fixture_pools

    stdout, stderr = io.StringIO(), io.StringIO()
    status = 0
    try:
        checker.ROOT = root
        checker.POOLS = fixture_pools
        checker.controls = controls
        with redirect_stdout(stdout), redirect_stderr(stderr):
            try:
                checker.main()
            except SystemExit as error:
                assert error.code is None or isinstance(error.code, int), error
                status = error.code or 0
    finally:
        checker.ROOT = original_root
        checker.POOLS = original_pools
        checker.controls = original_controls
    return status, stdout.getvalue(), stderr.getvalue()


def main():
    path = Path(sys.argv[1]) if len(sys.argv) == 2 else (
        ROOT / "scripts/check_slot_pool_entries.py")
    checker = load_checker(path)
    value = "is used as a function value and reaches a slot acquire"
    held = "holds a ExecWindowSlot and reaches entry, an entry point"
    sleep = "reaches a scheduler sleep; release the slot before the wait"
    cases = [
        ("direct nonholder", "fn dispatch() { entry(); }", None),
        ("holder local alias",
         "fn holder(slot: borrow ExecWindowSlot[0]) {\n"
         "    let callback = entry; callback();\n}\n"
         "fn probe() { let slot = exec_window_slot_acquire();\n"
         "    holder(slot); exec_window_slot_release(slot); }", held),
        ("nonholder local value", "fn dispatch() { let callback = entry; callback(); }",
         "entry " + value),
        ("holder transitive alias", "fn helper() { entry(); }\n"
         "fn holder(slot: borrow ExecWindowSlot[0]) {\n"
         "    let callback = helper; callback(); }", held),
        ("acquire alias", "fn dispatch() {\n"
         "    let take = exec_window_slot_acquire; let slot = take();\n"
         "    exec_window_slot_release(slot); }", ACQUIRE + " " + value),
        ("global entry alias", "let callback: fn() = entry;\n"
         "fn holder(slot: borrow ExecWindowSlot[0]) { callback(); }",
         "entry " + value),
        ("stored transitive helper", "struct Callbacks { call: fn(); }\n"
         "let mut callbacks: Callbacks;\nfn helper() { entry(); }\n"
         "fn install() { callbacks.call = helper; }\n"
         "fn holder(slot: borrow ExecWindowSlot[0]) { callbacks.call(); }",
         "helper " + value),
        ("returned helper", "fn helper() { entry(); }\n"
         "fn make_callback() -> fn() { return helper; }", "helper " + value),
        ("passed entry", "fn install() { register_callback(entry); }",
         "entry " + value),
        ("safe holder alias", "fn safe() {}\n"
         "fn holder(slot: borrow ExecWindowSlot[0]) {\n"
         "    let callback = safe; callback(); }", None),
        ("comment and string names", "fn holder(slot: borrow ExecWindowSlot[0]) {\n"
         '    print("entry exec_window_slot_acquire()"); // entry\n}', None),
        ("indirect scheduler sleep", "fn holder(slot: borrow ExecWindowSlot[0]) {\n"
         "    let callback = kernel_process_block_control; callback(); }", sleep),
        ("transitive scheduler sleep", "fn helper() { kernel_process_block_control(); }\n"
         "fn holder(slot: borrow ExecWindowSlot[0]) {\n"
         "    let callback = helper; callback(); }", sleep),
        ("global scheduler callback", "let callback: fn() = kernel_process_block_control;\n"
         "fn holder(slot: borrow ExecWindowSlot[0]) { callback(); }",
         "kernel_process_block_control is used as a function value and reaches a scheduler sleep"),
        ("stored outer lock callback", "struct Callbacks { call: fn(); }\n"
         "let mut callbacks: Callbacks;\nfn ext2_mutation_take() {}\n"
         "fn install() { callbacks.call = ext2_mutation_take; }\n"
         "fn holder(slot: borrow ExecWindowSlot[0]) { callbacks.call(); }",
         "ext2_mutation_take is used as a function value and reaches the ext2 mutation lock"),
        ("indirect outer lock", "fn ext2_mutation_take() {}\n"
         "fn holder(slot: borrow ExecWindowSlot[0]) {\n"
         "    let callback = ext2_mutation_take; callback(); }",
         "reaches ext2_mutation_take, which is outside it"),
        ("returned slot", "fn leak() -> ExecWindowSlot[0] {}",
         "leak returns a ExecWindowSlot; a slot must be released"),
    ]
    count = CaseCount()
    with tempfile.TemporaryDirectory(prefix="takibi-slot-controls-") as tmp:
        root = Path(tmp)
        (root / "kernel").mkdir()
        for label, extra, diagnostic in cases:
            (root / "kernel/pool.tkb").write_text(BASE + extra + "\n")
            original = checker.ROOT, checker.POOLS, checker.controls
            status, stdout, stderr = invoke(checker, root)
            count.note()
            assert all(before is after for before, after in zip(
                original, (checker.ROOT, checker.POOLS, checker.controls))), label
            output = stdout + stderr
            if diagnostic is None:
                assert status == 0, (label, status, output)
                assert "PASS slot-pool-entries:" in output, (label, output)
            else:
                assert status != 0, (label, "accepted", output)
                assert diagnostic in output, (label, diagnostic, output)
    report_pass("slot-pool-entries-controls",
                "direct nonholders accept; aliases and escaped acquiring "
                "callbacks reject without weakening sleep, rank or return checks",
                scenarios=count.ran)


if __name__ == "__main__":
    main()
