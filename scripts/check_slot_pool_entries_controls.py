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
BLOCK_POOL = ("kernel/drivers/block/memory.tkb", "block_slot_acquire",
              "BlockSlot", "leaf")
BLOCK_MINT = """linear struct BlockSlot[unit: usize] { private index: usize; }
fn block_slot_acquire_from(hint: usize) -> BlockSlot[0] {
    let mut slot: BlockSlot[0] = { hint }; return slot;
}
fn block_slot_release(slot: sink BlockSlot[0]) {}
"""
BLOCK_MEMORY = """fn block_slot_acquire() -> BlockSlot[0] {
    return block_slot_acquire_from(0);
}
fn block_read() {
    let slot = block_slot_acquire(); block_slot_release(slot);
}
fn kernel_process_block_control() {}
"""


def load_checker(path):
    spec = importlib.util.spec_from_file_location("slot_checker", path)
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    return checker


def invoke(checker, root, pool=None):
    """Call the real main and observe its real exit branch without waiting.

    The original built-in controls keep their production pool configuration;
    only the temporary one-pool source tree uses the holders fixture rule.
    Unexpected exceptions propagate instead of becoming intended rejections.
    """
    original_root = checker.ROOT
    original_pools = checker.POOLS
    original_controls = checker.controls
    fixture_pools = [pool or (
        "kernel/pool.tkb", ACQUIRE, "ExecWindowSlot", "holders")]

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


def check_case(checker, root, label, diagnostic, count, pool=None):
    original = checker.ROOT, checker.POOLS, checker.controls
    status, stdout, stderr = invoke(checker, root, pool)
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
            check_case(checker, root, label, diagnostic, count)
        (root / "kernel/pool.tkb").unlink()
        block = root / "kernel/drivers/block"
        block.mkdir(parents=True)
        (block / "block_slot.tkb").write_text(BLOCK_MINT)
        same_pool = "which is the same pool; with more holders than cores"
        block_cases = [
            ("single wrapper and backing issuer", "", "", None),
            ("foreign holder calls public entry", "",
             "fn cache_helper(slot: borrow BlockSlot[0]) { block_read(); }",
             "cache_helper holds a BlockSlot and reaches block_slot_acquire, " + same_pool),
            ("direct second acquire",
             "fn double() { let first = block_slot_acquire();\n"
             "    let second = block_slot_acquire();\n"
             "    block_slot_release(second); block_slot_release(first); }", "",
             "double holds a BlockSlot and reaches block_slot_acquire, " + same_pool),
            ("foreign holder takes backing issuer", "",
             "fn cache_helper(slot: borrow BlockSlot[0]) {\n"
             "    let other = block_slot_acquire_from(0); block_slot_release(other); }",
             "cache_helper holds a BlockSlot and reaches block_slot_acquire_from, " + same_pool),
            ("backing issuer value",
             "fn install() { let callback = block_slot_acquire_from; }", "",
             "block_slot_acquire_from " + value),
            ("foreign holder aliases backing issuer", "",
             "fn cache_helper(slot: borrow BlockSlot[0]) {\n"
             "    let callback = block_slot_acquire_from;\n"
             "    let other = callback(0); block_slot_release(other); }",
             "cache_helper holds a BlockSlot and reaches block_slot_acquire_from, " + same_pool),
            ("outer lock before first acquire",
             "fn ext2_mutation_take() {}\nfn ordered() {\n"
             "    ext2_mutation_take(); let slot = block_slot_acquire_from(0);\n"
             "    block_slot_release(slot); }", "", None),
        ]
        held_block = ("operation holds a BlockSlot and reaches block_slot_acquire, "
                      + same_pool)
        interval_cases = [
            ("USB retirement around guarded work",
             "block_read(); let slot: BlockSlot[0] = block_slot_acquire(); "
             "let guard = block_device_take(slot); work(guard); "
             "block_device_give(guard); block_slot_release(slot); block_read();", None),
            ("entry before release", "let slot = block_slot_acquire(); "
             "block_read(); block_slot_release(slot);", held_block),
            ("entry after release", "let slot = block_slot_acquire(); "
             "block_slot_release(slot); block_read();", None),
            ("between two held intervals", "let a = block_slot_acquire(); "
             "block_slot_release(a); block_read(); let b = block_slot_acquire(); "
             "block_slot_release(b); block_read();", None),
            ("second held interval", "let a = block_slot_acquire(); "
             "block_slot_release(a); let b = block_slot_acquire(); "
             "block_read(); block_slot_release(b);", held_block),
            ("wrong release name", "let slot = block_slot_acquire(); "
             "block_slot_release(other); block_read();", held_block),
            ("conditional release", "let slot = block_slot_acquire(); "
             "if (flag) { block_slot_release(slot); } block_read();", held_block),
            ("same-depth sibling release", "if (flag) { "
             "let slot = block_slot_acquire(); } else { "
             "block_slot_release(slot); } block_read();", held_block),
            ("shadowed release name", "let slot = block_slot_acquire(); "
             "{ let slot = other; } block_slot_release(slot); block_read();", held_block),
            ("reassigned release name", "let mut slot = block_slot_acquire(); "
             "slot = other; block_slot_release(slot); block_read();", held_block),
            ("operator reassign", "let mut slot = block_slot_acquire(); "
             "slot += other; block_slot_release(slot); block_read();", held_block),
            ("unknown release helper", "let slot = block_slot_acquire(); "
             "finish(slot); block_read();", held_block),
            ("short circuit release expression", "let slot = block_slot_acquire(); "
             "flag && block_slot_release(slot); block_read();", held_block),
            ("nested second acquisition argument",
             "let slot = block_slot_acquire_from(block_slot_acquire()); "
             "block_slot_release(slot);", held_block),
            ("non-let acquisition", "save(block_slot_acquire()); block_read();", held_block),
            ("comment and literal release", "let slot = block_slot_acquire(); "
             'print("block_slot_release(slot);"); /* block_slot_release(slot); */ '
             "block_read();", held_block),
            ("relayout and comments", "let /* binding */ slot: BlockSlot[0]\n"
             " = block_slot_acquire\n(\n);\nblock_slot_release\n( /* arg */ slot\n);\n"
             "block_read();", None),
            ("released backing issuer", "let slot = block_slot_acquire_from(0); "
             "block_slot_release(slot); block_read();", None),
            ("outer lock after release", "let slot = block_slot_acquire(); "
             "block_slot_release(slot); ext2_mutation_take();", None),
            ("outer lock while held", "let slot = block_slot_acquire(); "
             "ext2_mutation_take(); block_slot_release(slot);",
             "operation holds a BlockSlot and reaches ext2_mutation_take, which is outside it"),
            ("unknown acquisition expression", "let slot = wrap(block_slot_acquire()); "
             "block_slot_release(slot); block_read();", held_block),
            ("nested conditional acquisition", "if (flag) { let slot = block_slot_acquire(); "
             "block_slot_release(slot); } block_read();", None),
        ]
        for label, body, diagnostic in interval_cases:
            block_cases.append((label, "", "fn operation() { " + body + " }", diagnostic))
        block_cases.append(("borrowed holder remains held", "",
                            "fn operation(slot: borrow BlockSlot[0]) { "
                            "block_slot_release(slot); block_read(); }", held_block))
        sleep_block = ("operation holds a BlockSlot and calls "
                       "kernel_process_block_control, which " + sleep)
        foreign_sleep_cases = [
            ("foreign borrowed direct sleep",
             "fn operation(slot: borrow BlockSlot[0]) { "
             "kernel_process_block_control(); }", sleep_block),
            ("foreign borrowed release does not end loan",
             "fn operation(slot: borrow BlockSlot[0]) { "
             "block_slot_release(slot); kernel_process_block_control(); }", sleep_block),
            ("foreign borrowed transitive sleep",
             "fn helper() { kernel_process_block_control(); }\n"
             "fn operation(slot: borrow BlockSlot[0]) { helper(); }",
             "operation holds a BlockSlot and calls helper, which " + sleep),
            ("foreign borrowed indirect sleep",
             "fn operation(slot: borrow BlockSlot[0]) { "
             "let callback = kernel_process_block_control; callback(); }", sleep_block),
            ("foreign borrowed indirect transitive sleep",
             "fn helper() { kernel_process_block_control(); }\n"
             "fn operation(slot: borrow BlockSlot[0]) { "
             "let callback = helper; callback(); }",
             "operation holds a BlockSlot and calls helper, which " + sleep),
            ("foreign local direct sleep",
             "fn operation() { let slot = block_slot_acquire(); "
             "kernel_process_block_control(); block_slot_release(slot); }", sleep_block),
            ("foreign local backing issuer sleep",
             "fn operation() { let slot = block_slot_acquire_from(0); "
             "kernel_process_block_control(); block_slot_release(slot); }", sleep_block),
            ("foreign local transitive sleep",
             "fn helper() { kernel_process_block_control(); }\n"
             "fn operation() { let slot = block_slot_acquire(); "
             "helper(); block_slot_release(slot); }",
             "operation holds a BlockSlot and calls helper, which " + sleep),
            ("foreign local indirect sleep",
             "fn operation() { let slot = block_slot_acquire(); "
             "let callback = kernel_process_block_control; callback(); "
             "block_slot_release(slot); }", sleep_block),
            ("foreign sleep after release",
             "fn operation() { let slot = block_slot_acquire(); "
             "block_slot_release(slot); kernel_process_block_control(); }", None),
            ("foreign transitive sleep after release",
             "fn helper() { kernel_process_block_control(); }\n"
             "fn operation() { let slot = block_slot_acquire(); "
             "block_slot_release(slot); helper(); }", None),
            ("foreign sleep before acquire",
             "fn operation() { kernel_process_block_control(); "
             "let slot = block_slot_acquire(); block_slot_release(slot); }", None),
            ("foreign conditional release still held",
             "fn operation() { let slot = block_slot_acquire(); "
             "if (flag) { block_slot_release(slot); } "
             "kernel_process_block_control(); }", sleep_block),
            ("foreign safe borrowed holder",
             "fn safe() {} fn operation(slot: borrow BlockSlot[0]) { safe(); }", None),
            ("foreign direct nonholder sleep",
             "fn operation() { kernel_process_block_control(); }", None),
            ("foreign retained-stack TaskMutex wait",
             "fn kernel_task_mutex_park() {}\n"
             "fn operation(slot: borrow BlockSlot[0]) { kernel_task_mutex_park(); }", None),
            ("foreign borrowed comments and literals",
             'fn operation(slot: borrow BlockSlot[0]) { '
             'print("kernel_process_block_control()"); '
             '/* kernel_process_block_control(); */ }', None),
        ]
        foreign_cases = foreign_sleep_cases + [
            ("foreign returned acquired slot",
             "fn leak() -> BlockSlot[0] { let slot = block_slot_acquire(); "
             "return slot; }",
             "leak returns a BlockSlot; a slot must be released"),
            ("foreign returned sink slot",
             "fn leak(slot: sink BlockSlot[0]) -> BlockSlot[0] { return slot; }",
             "leak returns a BlockSlot; a slot must be released"),
            ("foreign returned borrowed slot",
             "fn leak(slot: borrow BlockSlot[0]) -> borrow BlockSlot[0] { return slot; }",
             "leak returns a BlockSlot; a slot must be released"),
            ("foreign sink release",
             "fn consume(slot: sink BlockSlot[0]) { block_slot_release(slot); }", None),
            ("foreign borrowed scalar return",
             "fn number(slot: borrow BlockSlot[0]) -> usize { return slot.index; }", None),
        ]
        block_cases.extend((label, "", cache, diagnostic)
                           for label, cache, diagnostic in foreign_cases)
        for label, memory, cache, diagnostic in block_cases:
            (block / "memory.tkb").write_text(BLOCK_MEMORY + memory + "\n")
            (block / "block_cache.tkb").write_text(cache + "\n")
            check_case(checker, root, label, diagnostic, count, BLOCK_POOL)
        # Repeat the file-boundary discriminators for every existing pool.
        for _, acquire, token, _ in checker.POOLS:
            if token == "BlockSlot":
                continue
            release = acquire.removesuffix("_acquire") + "_release"
            pool = ("kernel/pool.tkb", acquire, token, "holders")
            (root / "kernel/pool.tkb").write_text(
                f"fn {acquire}() -> {token}[0] {{}}\n"
                f"fn {release}(slot: sink {token}[0]) {{}}\n"
                f"fn entry() {{ let slot = {acquire}(); {release}(slot); }}\n"
                "fn kernel_process_block_control() {}\n")
            for label, body, diagnostic in [
                ("borrowed", f"fn held(slot: borrow {token}[0]) {{ bridge(); }}",
                 f"held holds a {token} and calls bridge, which " + sleep),
                ("acquired", f"fn held() {{ let slot = {acquire}(); "
                 f"bridge(); {release}(slot); }}",
                 f"held holds a {token} and calls bridge, which " + sleep),
                ("released", f"fn held() {{ let slot = {acquire}(); "
                 f"{release}(slot); bridge(); }}", None),
                ("returned", f"fn leak() -> {token}[0] {{ "
                 f"let slot = {acquire}(); return slot; }}",
                 f"leak returns a {token}; a slot must be released"),
                ("sink release", f"fn consume(slot: sink {token}[0]) {{ "
                 f"{release}(slot); }}", None),
                ("borrowed scalar", f"fn number(slot: borrow {token}[0]) "
                 "-> usize { return slot.index; }", None),
            ]:
                # Separate holder, bridge and pool files exercise the global closure.
                (block / "block_cache.tkb").write_text(body)
                (block / "memory.tkb").write_text(
                    "fn bridge() { kernel_process_block_control(); }\n")
                (block / "block_slot.tkb").write_text("")
                check_case(checker, root, token + " foreign " + label,
                           diagnostic, count, pool)
    report_pass("slot-pool-entries-controls",
                "direct nonholders accept; aliases and escaped acquiring "
                "callbacks reject; foreign holders obey sleep and return rules "
                f"without weakening rank or release intervals ({count.ran} scenarios)",
                scenarios=count.ran)


if __name__ == "__main__":
    main()
