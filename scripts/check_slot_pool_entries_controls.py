#!/usr/bin/env python3
"""Exercise the actual slot checker on direct calls and escaped callbacks.

The temporary source is a host-check fixture, never an executed kernel.
An optional checker path permits the same controls to reject an old checker.
Every negative requires both nonzero exit and its particular diagnostic.
"""

import os
from pathlib import Path
import subprocess
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
HARNESS = r"""import importlib.util, pathlib, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[3])
spec = importlib.util.spec_from_file_location('slot_checker', sys.argv[1])
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
checker.ROOT = pathlib.Path(sys.argv[2])
production_pools, production_controls = checker.POOLS, checker.controls
def controls():
    # Its built-in rank controls cover all five production pools. Run them
    # unchanged under their own configuration, then check this one-pool tree.
    fixture_pools = checker.POOLS
    checker.POOLS = production_pools
    try:
        production_controls()
    finally:
        checker.POOLS = fixture_pools
checker.controls = controls
checker.POOLS = [('kernel/pool.tkb', 'exec_window_slot_acquire',
                  'ExecWindowSlot', 'holders')]
checker.main()
"""


def main():
    checker = Path(sys.argv[1]) if len(sys.argv) == 2 else (
        ROOT / "scripts/check_slot_pool_entries.py")
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
            result = subprocess.run(
                [sys.executable, "-c", HARNESS, str(checker.resolve()), str(root),
                 str(ROOT / "scripts")], capture_output=True, text=True,
                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"), timeout=3)
            count.note()
            output = result.stdout + result.stderr
            if diagnostic is None:
                assert result.returncode == 0, (label, result.returncode, output)
                assert "PASS slot-pool-entries:" in output, (label, output)
            else:
                assert result.returncode != 0, (label, "accepted", output)
                assert diagnostic in output, (label, diagnostic, output)
    report_pass("slot-pool-entries-controls",
                "direct nonholders accept; aliases and escaped acquiring "
                "callbacks reject without weakening sleep, rank or return checks",
                scenarios=count.ran)


if __name__ == "__main__":
    main()
