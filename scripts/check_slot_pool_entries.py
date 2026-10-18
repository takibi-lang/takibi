#!/usr/bin/env python3
"""An operation holds one slot of a scratch pool at a time (#638).

Per-operation scratch that an operation holds across a call that may block
lives in a pool of KERNEL_MAX_CORES slots, handed out as a linear token:
kernel/fs/ext2/ext2.tkb's Ext2Slot (slice 2) and
kernel/drivers/block/memory.tkb's BlockSlot (slice 3) and
kernel/mm/process_image.tkb's ProcessImageSlot (the exec staging). The compiler checks
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

SyscallSlot (kernel/kernel/syscall.tkb) is a pool whose entry points the
same file's dispatcher calls, so "never called from inside the file" cannot
hold for it. Its rule is the one the leaf rule approximates: no function
that holds a slot -- one handed a SyscallSlot, or one that acquires it --
reaches an entry point through the file's call graph.

No slot is held across a sleeping wait (maintainer, 2026-10-17). A syscall
sleeps only after its handler has returned: the dispatcher hands back
SyscallAction::Block and kernel_syscall_block_return calls one of
process.tkb's kernel_process_block_* functions. A slot-holding function of
any pool must not reach one of those through the kernel's call graph
(names resolved over every kernel .tkb file, so a cross-file path counts),
and a pool's token never appears in a return type other than its acquire's,
so it cannot outlive the function that acquired it and be carried to the
sleep. Bounded waits -- a TaskMutex, a device completion -- are not sleeps
and stay allowed.

BlockSlot also covers kernel/drivers/block/block_cache.tkb, whose entries
are indexed by the slot's number as a plain usize: only memory.tkb (and the
linux_user test that plays two writers) may call its slot-indexed functions,
so every index it is handed belongs to a live BlockSlot.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only

ROOT = Path(__file__).resolve().parent.parent
# (file, acquire, token, rule): "leaf" -- no function in the file names an
# entry point; "holders" -- no slot holder reaches one.
POOLS = [
    ("kernel/fs/ext2/ext2.tkb", "ext2_slot_acquire", "Ext2Slot", "leaf"),
    ("kernel/drivers/block/memory.tkb", "block_slot_acquire", "BlockSlot",
     "leaf"),
    ("kernel/mm/process_image.tkb", "process_image_slot_acquire",
     "ProcessImageSlot", "leaf"),
    ("kernel/kernel/syscall.tkb", "syscall_slot_acquire", "SyscallSlot",
     "holders"),
]
# The scheduler sleeps a syscall takes after its handler returns.
SLEEP = re.compile(r"^(?:kernel_process_block_\w+|kernel_syscall_block_return)$")
CALL = re.compile(r"\b(\w+)\s*\(")
# block_cache.tkb's functions that take a BlockSlot's index.
SLOT_INDEXED = ["block_cache_read", "block_cache_fill",
                "block_cache_note_write", "block_cache_forget_all"]
SLOT_INDEX_CALLERS = {"kernel/drivers/block/memory.tkb",
                      "kernel/drivers/block/block_cache.tkb",
                      "linux_user/block_cache/block_cache.tkb"}
FUNCTION = re.compile(r"^(?:private\s+)?(?:(?:no)?inline\s+)?fn\s+(\w+)\s*\(", re.M)


# Shared with every code-property check: blanks `//` and `/* */` comments,
# keeps string literals (GitHub issue #815).
strip_comments = code_only


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


def callees(body, known):
    return {m.group(1) for m in CALL.finditer(body)} & known


def reach(start, graph):
    """Functions reachable from start (start itself only through a cycle)."""
    seen, todo = set(), list(graph.get(start, ()))
    while todo:
        name = todo.pop()
        if name in seen:
            continue
        seen.add(name)
        todo.extend(graph.get(name, ()))
    return seen


def holders_of(fns, acquire, token):
    return {name for name, (signature, body) in fns.items()
            if name != acquire and
            (re.search(r"\b" + token + r"\b", signature) or
             re.search(r"\b" + acquire + r"\s*\(", body))}


def problems_in(text, acquire, token, rule="leaf", sleepers=frozenset()):
    fns = functions(text)
    entries = {name for name, (_, body) in fns.items()
               if re.search(r"\b" + acquire + r"\s*\(", body)}
    problems = []
    for entry in sorted(entries):
        if re.search(r"\b" + token + r"\b", fns[entry][0]):
            problems.append(f"{entry} acquires a slot while it is handed one")
    graph = {name: callees(body, set(fns))
             for name, (signature, body) in fns.items()}
    if rule == "leaf":
        for entry in sorted(entries):
            for name, (signature, body) in fns.items():
                if name == entry:
                    continue
                if re.search(r"\b" + entry + r"\b", signature + body):
                    problems.append(
                        f"{name} calls {entry}, an entry point that acquires "
                        "its own slot; pass the caller's slot to the "
                        "internal version instead")
    for holder in sorted(holders_of(fns, acquire, token)):
        if rule == "holders":
            for entry in sorted(reach(holder, graph) & entries):
                problems.append(
                    f"{holder} holds a {token} and reaches {entry}, an entry "
                    "point that acquires its own slot; pass the caller's "
                    "slot to the internal version instead")
        signature, body = fns[holder]
        for callee in sorted({m.group(1) for m in CALL.finditer(body)}):
            if callee in sleepers or SLEEP.match(callee):
                problems.append(
                    f"{holder} holds a {token} and calls {callee}, which "
                    "reaches a scheduler sleep; release the slot before "
                    "the wait")
    for name, (signature, _) in fns.items():
        if name == acquire:
            continue
        arrow = signature.find("->")
        if arrow >= 0 and re.search(r"\b" + token + r"\b", signature[arrow:]):
            problems.append(
                f"{name} returns a {token}; a slot must be released by the "
                "function that acquired it")
    return entries, problems


def sleepers_in(files):
    """Every kernel function from which a scheduler sleep is reachable."""
    fns = {}
    for path, text in files.items():
        if not path.startswith("kernel/"):
            continue
        for name, (signature, body) in functions(text).items():
            fns.setdefault(name, []).append(body)
    graph = {}
    for name, bodies in fns.items():
        called = set()
        for body in bodies:
            called |= {m.group(1) for m in CALL.finditer(body)}
        graph[name] = called
    sleeping = {name for name, called in graph.items()
                if SLEEP.match(name)}
    sleeping |= {c for called in graph.values() for c in called
                 if SLEEP.match(c)}
    changed = True
    while changed:
        changed = False
        for name, called in graph.items():
            if name not in sleeping and called & sleeping:
                sleeping.add(name)
                changed = True
    return sleeping


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
    for _, acquire, token, _ in POOLS:
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
    acquire, token = "syscall_slot_acquire", "SyscallSlot"
    holder_base = (f"private fn {acquire}() -> {token}[0] {{ }}\n"
                   "fn op_a(x: usize) -> usize {\n"
                   f"    let slot: {token}[0] = {acquire}();\n"
                   "    op_a_with(slot);\n}\n"
                   f"fn op_a_with(slot: borrow {token}[0]) {{ }}\n"
                   "fn dispatch() { op_a(1); }\n")
    if problems_in(holder_base, acquire, token, "holders")[1]:
        print("ERROR slot-pool-entries: the dispatcher's call of an entry "
              "was reported, though it holds no slot")
        sys.exit(1)
    holder_cases = {
        "holder reaching an entry through a helper":
            holder_base + "fn helper() { op_a(2); }\n"
            f"fn op_b_with(slot: borrow {token}[0]) {{ helper(); }}\n",
        "holder calling a scheduler sleep":
            holder_base + f"fn op_c_with(slot: borrow {token}[0]) {{\n"
            "    kernel_process_block_wait4(1);\n}\n",
        "holder calling a function that sleeps":
            holder_base + f"fn op_d_with(slot: borrow {token}[0]) {{\n"
            "    deep_wait(1);\n}\n",
        "slot returned out of its function":
            holder_base + f"fn op_e() -> {token}[0] {{ }}\n",
    }
    for label, text in holder_cases.items():
        if not problems_in(text, acquire, token, "holders",
                           frozenset({"deep_wait"}))[1]:
            print(f"ERROR slot-pool-entries: control '{label}' was not "
                  "detected")
            sys.exit(1)
    if "deep_wait" not in sleepers_in({"kernel/x.tkb":
            "fn deep_wait(x: usize) { mid(x); }\n"
            "fn mid(x: usize) { kernel_process_block_net(x); }\n"}):
        print("ERROR slot-pool-entries: control 'transitive sleeper' was not "
              "detected")
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
    files = {}
    for tree in ("kernel", "linux_user"):
        for source in (ROOT / tree).rglob("*.tkb"):
            files[str(source.relative_to(ROOT))] = source.read_text()
    sleepers = sleepers_in(files)
    if not any(SLEEP.match(name) for name in sleepers):
        print("ERROR slot-pool-entries: no kernel_process_block_* function "
              "found; the sleep rule sees nothing")
        sys.exit(1)
    total = 0
    for path, acquire, token, rule in POOLS:
        entries, problems = problems_in(files[path], acquire, token, rule,
                                        frozenset(sleepers))
        if not entries:
            print(f"ERROR slot-pool-entries: no function in {path} calls "
                  f"{acquire}; the check sees nothing")
            sys.exit(1)
        if problems:
            for problem in problems:
                print(f"ERROR slot-pool-entries: {problem}")
            sys.exit(1)
        total += len(entries)
    index_problems = slot_index_problems(files)
    if index_problems:
        for problem in index_problems:
            print(f"ERROR slot-pool-entries: {problem}")
        sys.exit(1)
    report_pass("slot-pool-entries",
                f"{total} entry points across {len(POOLS)} slot pools acquire "
                "a slot, no slot holder reaches another entry point or any of "
                f"{len(sleepers)} functions that reach a scheduler sleep, and "
                "no slot is returned; the slot-indexed block cache is called "
                f"from memory.tkb only ({len(files)} files scanned, sixteen "
                "controls)",
                entries=total, files=len(files), sleepers=len(sleepers))


if __name__ == "__main__":
    main()
