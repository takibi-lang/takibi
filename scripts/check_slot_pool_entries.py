#!/usr/bin/env python3
"""An operation holds one slot of a scratch pool at a time (#638).

Per-operation scratch that an operation holds across a call that may block
lives in a pool of KERNEL_MAX_CORES slots, handed out as a linear token:
kernel/fs/ext2/ext2.tkb's Ext2Slot (slice 2) and
kernel/drivers/block/memory.tkb's BlockSlot (slice 3). The compiler checks
each token: released on every path, never released twice, never used after
release. What it does not check is how many tokens of one pool an operation
holds. If a function that holds a slot called a public entry point, which
acquires its own, one operation would hold two; with every CPU doing that,
every slot is held by an operation waiting in the acquire for another, and
the pool deadlocks.

So, per pool, the entry points -- the functions that call the acquire --
must be leaves of the file's call graph from the inside: no function in the
pool's file names one, and none of them is itself handed a slot. Internal
work takes the caller's slot as a `borrow` parameter instead. Other files
never hold a slot of the pool (the acquire is private), so calls from them
are fine.

BlockSlot also covers kernel/drivers/block/block_cache.tkb, whose entries
are indexed by the slot's number as a plain usize: only memory.tkb (and the
linux_user test that plays two writers) may call its slot-indexed functions,
so every index it is handed belongs to a live BlockSlot.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
POOLS = [
    ("kernel/fs/ext2/ext2.tkb", "ext2_slot_acquire", "Ext2Slot"),
    ("kernel/drivers/block/memory.tkb", "block_slot_acquire", "BlockSlot"),
]
# block_cache.tkb's functions that take a BlockSlot's index.
SLOT_INDEXED = ["block_cache_read", "block_cache_fill",
                "block_cache_note_write", "block_cache_forget_all"]
SLOT_INDEX_CALLERS = {"kernel/drivers/block/memory.tkb",
                      "kernel/drivers/block/block_cache.tkb",
                      "linux_user/block_cache/block_cache.tkb"}
FUNCTION = re.compile(r"^(?:private\s+)?(?:(?:no)?inline\s+)?fn\s+(\w+)\s*\(", re.M)


def strip_comments(text):
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def functions(text):
    """name -> (signature, body) with comments removed."""
    code = strip_comments(text)
    starts = [(m.start(), m.group(1)) for m in FUNCTION.finditer(code)]
    out = {}
    for index, (start, name) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(code)
        chunk = code[start:end]
        brace = re.search(r"(?<!!)\{", chunk)
        split = brace.start() if brace else len(chunk)
        out[name] = (chunk[:split], chunk[split:])
    return out


def problems_in(text, acquire, token):
    fns = functions(text)
    entries = {name for name, (_, body) in fns.items()
               if re.search(r"\b" + acquire + r"\s*\(", body)}
    problems = []
    for entry in sorted(entries):
        if re.search(r"\b" + token + r"\b", fns[entry][0]):
            problems.append(f"{entry} acquires a slot while it is handed one")
        for name, (signature, body) in fns.items():
            if name == entry:
                continue
            if re.search(r"\b" + entry + r"\b", signature + body):
                problems.append(
                    f"{name} calls {entry}, an entry point that acquires its "
                    "own slot; pass the caller's slot to the internal "
                    "version instead")
    return entries, problems


def slot_index_problems(files):
    """files: {relative path: text}. Callers of the slot-indexed cache."""
    problems = []
    for path, text in sorted(files.items()):
        if path in SLOT_INDEX_CALLERS:
            continue
        code = strip_comments(text)
        for name in SLOT_INDEXED:
            if re.search(r"\b" + name + r"\b", code):
                problems.append(
                    f"{path} names {name}, which takes a BlockSlot's index; "
                    "only memory.tkb holds BlockSlots")
    return problems


def controls():
    """The check must see the shapes it exists to catch."""
    for _, acquire, token in POOLS:
        base = (f"private fn {acquire}() -> {token}[0] {{ }}\n"
                "fn op_a(x: usize) -> usize {\n"
                f"    let slot: {token}[0] = {acquire}();\n}}\n")
        cases = {
            "internal call of an entry":
                base + f"fn op_b(slot: borrow {token}[0]) {{ op_a(1); }}\n",
            "entry that holds a slot":
                f"fn op_c(slot: borrow {token}[0]) {{\n"
                f"    let s: {token}[0] = {acquire}();\n}}\n",
        }
        for label, text in cases.items():
            if not problems_in(text, acquire, token)[1]:
                print(f"ERROR slot-pool-entries: {token} control '{label}' "
                      "was not detected")
                sys.exit(1)
        if problems_in(base + "fn op_b() { } // op_a(1)\n", acquire, token)[1]:
            print("ERROR slot-pool-entries: a comment was reported as a call")
            sys.exit(1)
    if not slot_index_problems(
            {"kernel/x.tkb": "fn f() { block_cache_fill(cpu_id(), 0, 0); }"}):
        print("ERROR slot-pool-entries: control 'cache indexed outside "
              "memory.tkb' was not detected")
        sys.exit(1)
    if slot_index_problems({"kernel/x.tkb": "// block_cache_fill(0)\n"}):
        print("ERROR slot-pool-entries: a comment was reported as a cache call")
        sys.exit(1)


def main():
    controls()
    total = 0
    for path, acquire, token in POOLS:
        entries, problems = problems_in((ROOT / path).read_text(),
                                        acquire, token)
        if not entries:
            print(f"ERROR slot-pool-entries: no function in {path} calls "
                  f"{acquire}; the check sees nothing")
            sys.exit(1)
        if problems:
            for problem in problems:
                print(f"ERROR slot-pool-entries: {problem}")
            sys.exit(1)
        total += len(entries)
    files = {}
    for tree in ("kernel", "linux_user"):
        for source in (ROOT / tree).rglob("*.tkb"):
            files[str(source.relative_to(ROOT))] = source.read_text()
    index_problems = slot_index_problems(files)
    if index_problems:
        for problem in index_problems:
            print(f"ERROR slot-pool-entries: {problem}")
        sys.exit(1)
    report_pass("slot-pool-entries",
                f"{total} entry points across {len(POOLS)} slot pools acquire "
                "a slot and none is called from inside its pool's file; the "
                f"slot-indexed block cache is called from memory.tkb only "
                f"({len(files)} files scanned, eight controls)",
                entries=total, files=len(files))


if __name__ == "__main__":
    main()
