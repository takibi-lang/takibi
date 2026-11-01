#!/usr/bin/env python3
"""An operation holds one slot of a scratch pool at a time (#638).

Per-operation scratch that an operation holds across a call that may block
lives in a pool of KERNEL_MAX_CORES slots, handed out as a linear token:
kernel/fs/ext2/ext2.tkb's Ext2Slot (slice 2) and
kernel/drivers/block/memory.tkb's BlockSlot (slice 3) and
kernel/mm/process_image.tkb's ProcessImageSlot (the exec staging) and
kernel/init/test_driver.tkb's ExecWindowSlot (the exec's ELF metadata). The compiler checks
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

Pools nest in one order, with the ext2 mutation lock outside them all (#993):
under preemption holders can outnumber cores, every slot of a pool can be held
at once, and a holder waiting for something outer completes a cycle. So over
the whole kernel call graph no holder of a pool reaches the mutation lock, or
the acquire of a pool ranked the same or further out (RANK). Also no function
handed a guard of a lower-level TaskMutex reaches any pool's acquire: those
guards are inside every pool. kernel/models/SlotPool.tla is the protocol.

BlockSlot also covers kernel/drivers/block/block_cache.tkb, whose entries
are indexed by the slot's number as a plain usize: only memory.tkb (and the
linux_user test that plays two writers) may call its slot-indexed functions,
so every index it is handed belongs to a live BlockSlot.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only, function_header

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
    ("kernel/init/test_driver.tkb", "exec_window_slot_acquire",
     "ExecWindowSlot", "leaf"),
]
# Nesting: a holder may reach only higher numbers. Syscall and exec scratch are
# siblings: neither reaches the other today, and equal ranks keep it so.
MUTATION_TAKE = "ext2_mutation_take"
RANK = {MUTATION_TAKE: 0, "syscall_slot_acquire": 1,
        "exec_window_slot_acquire": 1, "process_image_slot_acquire": 2,
        "ext2_slot_acquire": 3, "block_slot_acquire": 4}
# Guards of TaskMutexes that sit below every pool.
INNER_GUARDS = ["BlockDeviceGuard", "TcpConnectionOwner", "XhciRingGuard",
                "MscDmaGuard"]
# The scheduler sleeps a syscall takes after its handler returns.
SLEEP = re.compile(r"^(?:kernel_process_block_\w+|kernel_syscall_block_return)$")
CALL = re.compile(r"\b(\w+)\s*\(")
# block_cache.tkb's functions that take a BlockSlot's index.
SLOT_INDEXED = ["block_cache_read", "block_cache_fill",
                "block_cache_note_write", "block_cache_forget_all"]
SLOT_INDEX_CALLERS = {"kernel/drivers/block/memory.tkb",
                      "kernel/drivers/block/block_cache.tkb",
                      "linux_user/block_cache/block_cache.tkb"}
FUNCTION = function_header(suffix=r"\s*\(")


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


def nesting_problems(files):
    """Holders of a pool reaching something outer, over the kernel's graph."""
    fns = {}
    for path, text in files.items():
        if not path.startswith("kernel/") or "/tests/" in path:
            continue
        for name, (signature, body) in functions(text).items():
            fns.setdefault(name, []).append((signature, body))
    graph = {name: {m.group(1) for _, body in rows
                    for m in CALL.finditer(body)} & set(fns)
             for name, rows in fns.items()}
    problems = []
    for _, acquire, token, _ in POOLS:
        for holder in sorted(fns):
            if holder == acquire:
                continue
            held_calls = set()
            for signature, body in fns[holder]:
                taken = re.search(r"\b" + acquire + r"\s*\(", body)
                if re.search(r"\b" + token + r"\b", signature):
                    held_calls |= {m.group(1) for m in CALL.finditer(body)}
                elif taken:
                    # What the function did before the acquire, it did
                    # holding nothing: the mutation lock comes first.
                    held_calls |= {m.group(1) for m in
                                   CALL.finditer(body[taken.end():])}
            reached = set(held_calls)
            for callee in held_calls:
                reached |= reach(callee, graph)
            for target in sorted(reached & set(RANK)):
                if target == acquire or RANK[target] > RANK[acquire]:
                    continue
                problems.append(
                    f"{holder} holds a {token} and reaches {target}, which "
                    "is outside it; with more holders than cores that is a "
                    "deadlock (kernel/models/SlotPool.tla)")
    for token in INNER_GUARDS:
        for name, rows in sorted(fns.items()):
            if not any(re.search(r"\b" + token + r"\b", signature)
                       for signature, _ in rows):
                continue
            for target in sorted(reach(name, graph) & set(RANK)):
                problems.append(f"{name} holds a {token} and reaches {target}; "
                                "that lock is inside every slot pool")
    return problems


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
    outer = {
        "write holding a slot takes the mutation lock":
            "fn w(s: borrow SyscallSlot[0]) { h(); }\n"
            "fn h() { ext2_mutation_take(); }\n"
            "fn ext2_mutation_take() { }\n",
        "inner holder takes the outer pool":
            "fn f(s: borrow Ext2Slot[0]) { process_image_slot_acquire(); }\n"
            "fn process_image_slot_acquire() { }\n",
        "lock guard holder takes a pool":
            "fn f(g: borrow BlockDeviceGuard[x]) { block_slot_acquire(); }\n"
            "fn block_slot_acquire() { }\n",
    }
    for label, text in outer.items():
        if not nesting_problems({"kernel/x.tkb": text}):
            print(f"ERROR slot-pool-entries: control '{label}' was not "
                  "detected")
            sys.exit(1)
    if nesting_problems({"kernel/x.tkb":
                         "fn w() { ext2_mutation_take();\n"
                         "    syscall_slot_acquire(); }\n"
                         "fn ext2_mutation_take() { }\n"
                         "fn syscall_slot_acquire() { }\n"}):
        print("ERROR slot-pool-entries: the lock before the slot was reported")
        sys.exit(1)
    if nesting_problems({"kernel/x.tkb":
                         "fn f(s: borrow SyscallSlot[0]) { ext2_slot_acquire(); }\n"
                         "fn ext2_slot_acquire() { }\n"}):
        print("ERROR slot-pool-entries: the outer-to-inner order was reported")
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
    index_problems = slot_index_problems(files) + nesting_problems(files)
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
