#!/usr/bin/env python3
"""An ext2 operation holds one scratch slot at a time (#638 slice 2).

kernel/fs/ext2/ext2.tkb keeps the scratch an operation holds across block
I/O in a pool of KERNEL_MAX_CORES slots, handed out by ext2_slot_acquire as
a linear Ext2Slot. The compiler checks each token: released on every path,
never released twice, never used after release. What it does not check is
how many tokens one operation holds. If a function that holds a slot called
a public entry point, which acquires its own, one operation would hold two;
with every CPU doing that, every slot is held by an operation waiting in
ext2_slot_acquire for another, and the pool deadlocks.

So the entry points -- the functions that call ext2_slot_acquire -- must be
leaves of the file's call graph from the inside: no function in ext2.tkb
names one, and none of them is itself handed a slot. Internal work takes the
caller's slot as a `borrow Ext2Slot[0]` parameter instead. Other files never
hold a slot (the acquire is private), so calls from them are fine.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
EXT2 = ROOT / "kernel" / "fs" / "ext2" / "ext2.tkb"
ACQUIRE = "ext2_slot_acquire"
FUNCTION = re.compile(r"^(?:private\s+)?(?:noinline\s+)?fn\s+(\w+)\s*\(", re.M)


def functions(text):
    """name -> (signature, body) with comments removed."""
    code = "\n".join(line.split("//", 1)[0] for line in text.splitlines())
    starts = [(m.start(), m.group(1)) for m in FUNCTION.finditer(code)]
    out = {}
    for index, (start, name) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(code)
        chunk = code[start:end]
        brace = re.search(r"(?<!!)\{", chunk)
        split = brace.start() if brace else len(chunk)
        out[name] = (chunk[:split], chunk[split:])
    return out


def problems_in(text):
    fns = functions(text)
    entries = {name for name, (_, body) in fns.items()
               if re.search(r"\b" + ACQUIRE + r"\s*\(", body)}
    problems = []
    for entry in sorted(entries):
        if "Ext2Slot" in fns[entry][0]:
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


def controls():
    """The check must see the shapes it exists to catch."""
    acquire = ("private fn ext2_slot_acquire() -> Ext2Slot[0] { }\n"
               "fn ext2_a(x: usize) -> usize {\n"
               "    let slot: Ext2Slot[0] = ext2_slot_acquire();\n}\n")
    cases = {
        "internal call of an entry":
            acquire + "fn ext2_b(slot: borrow Ext2Slot[0]) { ext2_a(1); }\n",
        "entry that holds a slot":
            "fn ext2_c(slot: borrow Ext2Slot[0]) {\n"
            "    let s: Ext2Slot[0] = ext2_slot_acquire();\n}\n",
    }
    for label, text in cases.items():
        if not problems_in(text)[1]:
            print(f"ERROR ext2-slot-entries: control '{label}' was not "
                  "detected")
            sys.exit(1)
    if problems_in(acquire + "fn ext2_b() { } // ext2_a(1)\n")[1]:
        print("ERROR ext2-slot-entries: a comment was reported as a call")
        sys.exit(1)


def main():
    controls()
    entries, problems = problems_in(EXT2.read_text())
    if not entries:
        print("ERROR ext2-slot-entries: no function in kernel/fs/ext2/ext2.tkb "
              "calls ext2_slot_acquire; the check sees nothing")
        sys.exit(1)
    if problems:
        for problem in problems:
            print(f"ERROR ext2-slot-entries: {problem}")
        sys.exit(1)
    report_pass("ext2-slot-entries",
                f"{len(entries)} ext2 entry points acquire a scratch slot and "
                "none is called from inside ext2.tkb (three controls)",
                entries=len(entries))


if __name__ == "__main__":
    main()
