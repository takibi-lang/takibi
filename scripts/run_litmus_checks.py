#!/usr/bin/env python3
"""herd7 over the kernel log's litmus tests, and their tie to the emitted code.

GitHub issue #645, part of `make modelcheck`. Two checks:

1. herd7 (from opam, pinned in .devcontainer/devcontainer.json and CI,
   scripts/check_herdtools_pin.py) runs every kernel/models/litmus/*.litmus
   and each verdict must equal kernel/models/litmus/expected.txt: Never for
   a fixed test, Sometimes for an unfixed control.
2. The litmus tests must describe the instructions the compiler really
   emits. kernel/models/litmus/emitted_map.txt names, per litmus location,
   the Takibi functions and globals it stands for. This disassembles the
   RPi5 kernel object (built with one section per function, so each function is
   its own section and relocations name the globals), follows each global's
   address through registers and into the functions it calls, and requires
   every access of the thread's direction to use the litmus instruction's
   class (STLR, LDAR, STR, LDR, or for a compare-swap CAS, CASA, CASL,
   CASAL -- a load and a store at once, direction "rmw"), plus the stated
   program orders.

The tie is a lint over the disassembly, not a proof: it follows addresses
through register moves and adds and two levels of calls (a function, the
functions it calls, and the helpers they pass an address to), which is the
shape the compiler emits for the AtomicWord helpers and the log ring today. An access it cannot
follow (an address spilled to the stack, say) is not seen, so each row also
requires at least one access to exist, and the controls below plant the
defects the tie exists for.

Usage: run_litmus_checks.py <herd7> <llvm-objdump> <kernel object>
"""

import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
LITMUS = REPO / "kernel/models/litmus"

LOADS = re.compile(r"^(ldr|ldur|ldar|ldaxr|ldxr|ldp|ldapr)[bhw]?$|^(ldrs[bhw])$")
STORES = re.compile(r"^(str|stur|stlr|stlxr|stxr|stp)[bhw]?$")
CALL_CLOBBERED = {f"x{n}" for n in range(19)} | {"x30"}


def reg(name: str) -> str:
    name = name.strip().lower()
    if re.fullmatch(r"w\d+", name):
        return "x" + name[1:]
    return name


CAS = re.compile(r"^cas(a?)(l?)[bh]?$")


def mnemonic_class(mnemonic: str) -> str:
    """STLR/LDAR keep their name; any plain access is STR or LDR; an LSE
    compare-swap is CAS with its acquire (A) and release (L) suffixes."""
    m = mnemonic.lower()
    cas = CAS.match(m)
    if cas:
        return "CAS" + ("A" if cas.group(1) else "") + ("L" if cas.group(2) else "")
    if m.startswith("stlr"):
        return "STLR"
    if m.startswith("ldar"):
        return "LDAR"
    if STORES.match(m):
        return "STR"
    if LOADS.match(m):
        return "LDR"
    return m.upper()


# -- herd7 verdicts -----------------------------------------------------------

def expected_verdicts() -> dict:
    rows = {}
    for line in (LITMUS / "expected.txt").read_text(encoding="ascii").splitlines():
        line = line.split("#", 1)[0].split()
        if line:
            rows[line[0]] = line[1]
    return rows


def herd_verdicts(herd7: str, files: list) -> dict:
    out = subprocess.run([herd7, *map(str, files)], capture_output=True,
                         text=True, check=False)
    verdicts = {}
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == "Observation":
            verdicts[parts[1]] = parts[2]
    if out.returncode != 0 and not verdicts:
        sys.stderr.write(out.stderr)
    return verdicts


def verdict_problems(expected: dict, got: dict) -> list:
    found = []
    for name in sorted(set(expected) | set(got)):
        if name not in got:
            found.append(f"{name}: herd7 gave no verdict")
        elif name not in expected:
            found.append(f"{name}: no expected verdict in expected.txt")
        elif got[name] != expected[name]:
            found.append(f"{name}: herd7 says {got[name]}, expected {expected[name]}")
    return found


# -- litmus threads -----------------------------------------------------------

def direction_of(cls: str) -> str:
    if cls.startswith("CAS"):
        return "rmw"
    return "store" if cls in ("STR", "STLR") else "load"


def litmus_accesses(text: str) -> dict:
    """{(thread, location): (direction, class)} from a two-column litmus test."""
    lines = text.splitlines()
    init = {}
    body = []
    in_init = False
    for line in lines:
        if line.strip() == "{":
            in_init = True
            continue
        if line.strip() == "}":
            in_init = False
            continue
        if in_init:
            for item in line.split(";"):
                if "=" in item:
                    key, value = item.split("=", 1)
                    init[key.strip()] = value.strip()
        elif "|" in line and line.rstrip().endswith(";"):
            body.append(line.rstrip().rstrip(";").split("|"))
    header = [c.strip() for c in body[0]]
    accesses = {}
    for row in body[1:]:
        for index, cell in enumerate(row):
            cell = cell.strip()
            # LDAR X0,[X1] or CASAL X4,X2,[X3]: the address is the last.
            match = re.match(r"(\w+)\s+\w+\s*,\s*(?:\w+\s*,\s*)?\[(\w+)\]", cell)
            if not match:
                continue
            thread = header[index]
            location = init.get(f"{thread[1:]}:{match.group(2)}")
            cls = mnemonic_class(match.group(1))
            accesses[(thread, location)] = (direction_of(cls), cls)
    return accesses


# -- disassembly --------------------------------------------------------------

FUNC = re.compile(r"^[0-9a-f]+ <([\w.$]+)>:$")
INSN = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$")
RELOC = re.compile(r"^\s*[0-9a-f]+:\s+(R_AARCH64_\w+)\s+([\w.$]+)")


def parse_disassembly(text: str) -> dict:
    """{function: [(offset, mnemonic, operands, reloc_symbol)]}."""
    functions = {}
    current = None
    for line in text.splitlines():
        func = FUNC.match(line)
        if func:
            current = functions.setdefault(func.group(1), [])
            continue
        if current is None:
            continue
        reloc = RELOC.match(line)
        if reloc and current:
            offset, mnemonic, operands, _ = current[-1]
            current[-1] = (offset, mnemonic, operands, reloc.group(2))
            continue
        insn = INSN.match(line)
        if insn:
            current.append((int(insn.group(1), 16), insn.group(2).lower(),
                            insn.group(3).split("//")[0].strip(), None))
    return functions


def operands_of(text: str) -> list:
    return [o.strip() for o in re.split(r",(?![^\[]*\])", text) if o.strip()]


# How deep calls are followed: a function, what it calls, and what those
# call (the log ring's retain_line -> commit -> kernel_log_cas).
CALL_DEPTH = 2


def accesses(functions: dict, name: str, arg0=None, depth=0) -> list:
    """[(offset, direction, class, global)] the function makes to globals,
    its callees' attributed to the call. With arg0 set, its incoming x0 is
    that global's address (a helper)."""
    taint = {}
    if arg0:
        taint["x0"] = arg0
    found = []
    for offset, mnemonic, operand_text, symbol in functions.get(name, []):
        ops = operands_of(operand_text)
        if mnemonic == "adrp" and symbol:
            taint[reg(ops[0])] = symbol
            continue
        if mnemonic == "bl":
            if symbol in functions and depth < CALL_DEPTH:
                for _, d, c, g in accesses(functions, symbol,
                                           taint.get("x0"), depth + 1):
                    found.append((offset, d, c, g))
            for r in CALL_CLOBBERED:
                taint.pop(r, None)
            continue
        cls = mnemonic_class(mnemonic)
        memory = [o for o in ops if o.startswith("[")]
        if memory and cls.startswith("CAS"):
            base = reg(memory[0].strip("[]!").split(",")[0])
            if base in taint:
                found.append((offset, "rmw", cls, taint[base]))
            taint.pop(reg(ops[0]), None)
            continue
        if memory and cls in ("STR", "STLR", "LDR", "LDAR"):
            base = reg(memory[0].strip("[]!").split(",")[0])
            if cls in ("LDR",) and symbol:
                # A GOT load: the address of `symbol`, not an access to it.
                taint[reg(ops[0])] = symbol
                continue
            if base in taint:
                direction = "store" if cls in ("STR", "STLR") else "load"
                found.append((offset, direction, cls, taint[base]))
            if cls in ("LDR", "LDAR"):
                for dest in ops[:2 if mnemonic == "ldp" else 1]:
                    taint.pop(reg(dest), None)
            continue
        if not ops:
            continue
        dest = reg(ops[0])
        sources = [reg(o.split()[0]) for o in ops[1:]]
        if mnemonic in ("add", "sub", "mov", "orr") and any(s in taint for s in sources):
            taint[dest] = next(taint[s] for s in sources if s in taint)
        elif mnemonic == "add" and symbol:
            taint[dest] = symbol
        else:
            taint.pop(dest, None)
    return found


def map_rows() -> list:
    rows = []
    for line in (LITMUS / "emitted_map.txt").read_text(encoding="ascii").splitlines():
        words = line.split("#", 1)[0].split()
        if words:
            rows.append(words)
    return rows


def emitted_problems(functions: dict, litmus: dict, rows: list) -> tuple:
    found = []
    checked = 0
    for words in rows:
        if len(words) < 3:
            found.append(f"{' '.join(words)}: too few fields (a '#' starts a comment)")
            continue
        kind, test, thread = words[0], words[1], words[2]
        threads = litmus.get(test)
        if threads is None:
            found.append(f"{' '.join(words)}: no litmus test {test}")
            continue
        if kind == "access":
            location, function, globals_ = words[3], words[4], words[5:]
            if (thread, location) not in threads:
                found.append(f"{test} {thread} does not access {location}")
                continue
            direction, want = threads[(thread, location)]
            if function not in functions:
                found.append(f"{test} {thread} {location}: {function} is not in the kernel object")
                continue
            seen = [a for a in accesses(functions, function)
                    if a[1] == direction and a[3] in globals_]
            for g in globals_:
                mine = [a for a in seen if a[3] == g]
                if not mine:
                    found.append(f"{test} {thread} {location}: {function} has no "
                                 f"{direction} to {g} the tie can follow")
                for offset, _, cls, _ in mine:
                    checked += 1
                    if cls != want:
                        found.append(f"{test} {thread} {location}: {function}+{offset:#x} "
                                     f"{direction}s {g} with {cls}, the litmus test says {want}")
        elif kind in ("order", "order-first", "order-last"):
            # order: every access to A before every access to B.
            # order-first: the first access to A before every access to B
            #   (an acquire load that the copy after it depends on).
            # order-last: every access to A before the last access to B
            #   (a re-check after the copy).
            # Accesses of every direction the thread's litmus code makes.
            function, first, second = words[3], words[4], words[5]
            directions = {d for (t, _), (d, _) in threads.items() if t == thread}
            seen = [a for a in accesses(functions, function) if a[1] in directions]
            a_offsets = [a[0] for a in seen if a[3] == first]
            b_offsets = [a[0] for a in seen if a[3] == second]
            checked += 1
            if kind == "order":
                ok = a_offsets and b_offsets and max(a_offsets) < min(b_offsets)
                claim = f"every access of {first} must precede every access of {second}"
            elif kind == "order-first":
                ok = a_offsets and b_offsets and min(a_offsets) < min(b_offsets)
                claim = f"an access of {first} must precede every access of {second}"
            else:
                ok = a_offsets and b_offsets and max(a_offsets) < max(b_offsets)
                claim = f"every access of {first} must precede an access of {second}"
            if not ok:
                found.append(f"{test} {thread}: in {function}, {claim}")
        elif kind == "callorder":
            # Program order across functions: every call to A comes before
            # every call to B in the caller (text written, then committed).
            caller, callee_a, callee_b = words[3], words[4], words[5]
            calls = [(o, s) for o, m, _, s in functions.get(caller, []) if m == "bl"]
            a_offsets = [o for o, s in calls if s == callee_a]
            b_offsets = [o for o, s in calls if s == callee_b]
            checked += 1
            if caller not in functions:
                found.append(f"{test} {thread}: {caller} is not in the kernel object")
            elif not a_offsets or not b_offsets or max(a_offsets) >= min(b_offsets):
                found.append(f"{test} {thread}: in {caller}, every call to {callee_a} "
                             f"must precede every call to {callee_b}")
        elif kind == "pending":
            if threads is None or len(words) < 4:
                found.append(f"{' '.join(words)}: a pending row names a fixed test and why")
        else:
            found.append(f"unknown row kind {kind}")
    # GitHub issue #613 slice 2: every fixed test is tied, or says why not
    # yet. A test with neither would pass herd7 and silently bind nothing.
    tied = {w[1] for w in rows if w[0] in ("access", "order", "order-first",
                                          "order-last", "callorder")}
    pending = {w[1] for w in rows if w[0] == "pending"}
    for test in sorted(litmus):
        if test not in tied and test not in pending:
            found.append(f"{test}: no access row ties it to the emitted code, "
                         f"and no pending row says why")
        elif test in tied and test in pending:
            found.append(f"{test}: tied by access rows and still marked pending")
    return tuple(found), checked


def controls(functions: dict, litmus: dict, rows: list) -> list:
    """Each planted defect must be reported; returns the ones that were not."""
    missed = []

    def weaken(helper: str, old: str, new: str) -> dict:
        changed = dict(functions)
        changed[helper] = [(o, new if m == old else m, t, s)
                           for o, m, t, s in functions[helper]]
        return changed

    plants = {
        "publish helper emits a plain STR": (weaken("kernel_log_publish", "stlr", "str"), litmus),
        "observe helper emits a plain LDR": (weaken("kernel_log_observe", "ldar", "ldr"), litmus),
    }
    # GitHub issue #613 slice 4: the ring's every compare-swap is one helper.
    plants["the ring's compare-swap is CAS, not CASAL"] = (
        weaken("kernel_log_cas", "casal", "cas"), litmus)
    weak = {name: dict(threads) for name, threads in litmus.items()}
    weak["LogRingCommit"][("P0", "text")] = ("store", "STR")
    plants["litmus test claims a plain store"] = (functions, weak)

    # Mirror a function's offsets, so its first access becomes its last.
    def mirrored(name: str) -> dict:
        return {k: ([(len(v) * 4 - o, m, t, s) for o, m, t, s in v] if k == name else v)
                for k, v in functions.items()}

    plants["the line is committed before its text is written"] = (
        mirrored("kernel_log_retain_line"), litmus)
    # Cut the reader off after its last text copy: no re-check follows it.
    reader = functions.get("kernel_log_snapshot_record", [])
    copies = [o for o, m, _, sym in reader
              if m == "bl" and sym == "kernel_log_copy_slot_text"]
    if copies:
        plants["the reader keeps a copy without re-checking"] = (
            {**functions, "kernel_log_snapshot_record":
             [i for i in reader if i[0] <= max(copies)]}, litmus)
    else:
        missed.append("kernel_log_snapshot_record calls no kernel_log_copy_slot_text")
    for name, (funcs, lit) in plants.items():
        if not emitted_problems(funcs, lit, rows)[0]:
            missed.append(name)
    # A fixed test whose rows are all removed, with no pending row instead.
    untied = [w for w in rows if w[1] != "LogRingCommit"]
    if not emitted_problems(functions, litmus, untied)[0]:
        missed.append("a fixed test with neither access rows nor a pending row")
    return missed


def main() -> int:
    herd7, objdump, kernel_object = sys.argv[1:4]
    failed = False
    files = sorted(LITMUS.glob("*.litmus"))
    verdicts = herd_verdicts(herd7, files)
    for line in verdict_problems(expected_verdicts(), verdicts):
        print(f"FAIL litmus-herd7: {line}")
        failed = True
    if not failed:
        never = sum(1 for v in verdicts.values() if v == "Never")
        print(f"PASS litmus-herd7: {len(verdicts)} test(s), {never} forbidden as "
              f"fixed, {len(verdicts) - never} unfixed control(s) allowed")
    dis = subprocess.run([objdump, "-dr", "--no-show-raw-insn", kernel_object],
                         capture_output=True, text=True, check=True).stdout
    functions = parse_disassembly(dis)
    litmus = {p.stem: litmus_accesses(p.read_text(encoding="ascii"))
              for p in files if "+" not in p.stem}
    rows = map_rows()
    found, checked = emitted_problems(functions, litmus, rows)
    for line in found:
        print(f"FAIL litmus-emitted: {line}")
    missed = controls(functions, litmus, rows)
    for name in missed:
        print(f"FAIL litmus-emitted control: planted defect not reported: {name}")
    if found or missed:
        return 1
    if failed:
        return 1
    pending = sorted({w[1] for w in rows if w[0] == "pending"})
    print(f"PASS litmus-emitted: {checked} access(es) and orders in {kernel_object} "
          f"match {len(litmus) - len(pending)} fixed litmus test(s); "
          f"{len(pending)} pending until their code exists ({', '.join(pending) or 'none'}); "
          f"7 planted defects reported")
    return 0


if __name__ == "__main__":
    sys.exit(main())
