#!/usr/bin/env python3
"""Inventory explicit trusted boundaries in the maintained kernel build.

The source set comes from depfiles emitted by successful --forbid-trap builds.
This is an audit aid, not a proof: TRUSTED_BASE.md records the assumptions that
cannot be counted.

`--check-raw-deref TARGET AUDIT DEPFILE [--lower]` is the one gate in here
(GitHub issue #639, #637 stage 0). It holds a kernel build's raw-pointer
dereference sites, which the compiler lists with --emit-raw-deref-audit, to
the per-file budget in scripts/raw_deref_budget.tsv, and is run by the rules
that compile each kernel or standalone EL0 object. A ratchet: a file with no row, over its row or
UNDER its row fails, so the number only moves down by an edit made on purpose.
"""

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

from check_lock_discipline import ATOMIC_ALLOWED, ATOMIC_RE
from pass_line import report_pass

REPO_ROOT = Path(__file__).resolve().parent.parent
KERNEL_DIR = REPO_ROOT / "kernel"
ATOMIC_CATEGORY = "raw atomic operation"


def read_depfile_sources(depfile: Path) -> list[str]:
    if not depfile.exists():
        sys.exit(f"error: {depfile} does not exist -- run `make kernelbuild` first")
    text = depfile.read_text().replace("\\\n", " ")
    _, _, prereqs = text.partition(":")
    return sorted(set(p for p in prereqs.split() if p.endswith(".tkb")))


RAW_DEREF_BUDGET = Path(__file__).resolve().parent / "raw_deref_budget.tsv"


def read_raw_deref_budget(path: Path) -> dict[str, tuple[int, int, str]]:
    """file -> (plain, io, reason), from the tab separated budget."""
    rows = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4 or not fields[3].strip():
            sys.exit(f"error: {path.name}:{number}: a row is file, plain, io "
                     "and a reason, tab separated")
        if fields[0] in rows:
            sys.exit(f"error: {path.name}:{number}: {fields[0]} appears twice")
        rows[fields[0]] = (int(fields[1]), int(fields[2]), fields[3])
    return rows


def read_raw_deref_audit(path: Path) -> dict[str, list[int]]:
    """file -> [plain, io] counts, from --emit-raw-deref-audit's output."""
    lines = path.read_text().splitlines()
    if not lines or lines[0].split("\t")[:6] != [
            "file", "line", "column", "function", "form", "pointer"]:
        sys.exit(f"error: {path} is not a raw-deref audit")
    counts: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for line in lines[1:]:
        fields = line.split("\t")
        counts[fields[0]][1 if fields[5] == "io" else 0] += 1
    return dict(counts)


def raw_deref_problems(audit: dict[str, list[int]],
                       budget: dict[str, tuple[int, int, str]],
                       compiled: set[str], exists) -> list[str]:
    """Everything the ratchet refuses; `compiled` is this target's files."""
    problems = []
    for name in sorted(audit):
        plain, io = audit[name]
        if name not in budget:
            problems.append(
                f"{name}: {plain} plain and {io} io raw-pointer dereference "
                "site(s) and no row in scripts/raw_deref_budget.tsv; a new "
                "file that dereferences a raw pointer is declared there, "
                "with its reason")
    for name, (want_plain, want_io, _) in sorted(budget.items()):
        if not exists(name):
            problems.append(f"{name}: has a row and no longer exists; "
                            "delete the row")
        elif want_plain == 0 and want_io == 0:
            problems.append(f"{name}: a row of zero; delete the row")
        if name not in compiled:
            continue
        plain, io = audit.get(name, [0, 0])
        for kind, have, want in (("plain", plain, want_plain),
                                 ("io", io, want_io)):
            if have > want:
                problems.append(
                    f"{name}: {have} {kind} dereference site(s), over its "
                    f"budget of {want}; a new dereference is a decision, "
                    "made in the budget with a reason")
            elif have < want:
                problems.append(
                    f"{name}: {have} {kind} dereference site(s), under its "
                    f"budget of {want}; lower the row (`--lower` does it) so "
                    "the count cannot climb back unnoticed")
    return problems


def lower_raw_deref_budget(path: Path, audit: dict[str, list[int]],
                           compiled: set[str]) -> list[str]:
    """Lower every row of a compiled file to what it now has; never raise."""
    changed = []
    out = []
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if line.startswith("#") or len(fields) != 4 or fields[0] not in compiled:
            out.append(line)
            continue
        plain, io = audit.get(fields[0], [0, 0])
        want_plain, want_io = int(fields[1]), int(fields[2])
        new_plain, new_io = min(plain, want_plain), min(io, want_io)
        if (new_plain, new_io) != (want_plain, want_io):
            changed.append(f"{fields[0]}: {want_plain}/{want_io} -> "
                           f"{new_plain}/{new_io}")
        if (new_plain, new_io) == (0, 0):
            continue  # a zero row is deleted
        out.append("\t".join([fields[0], str(new_plain), str(new_io), fields[3]]))
    path.write_text("\n".join(out) + "\n")
    return changed


def check_raw_deref_main(args: list[str]) -> int:
    lower = "--lower" in args
    args = [arg for arg in args if arg != "--lower"]
    if len(args) != 3 or args[0] not in ("qemu", "rpi5", "el0"):
        sys.exit("usage: measure_trusted_base.py --check-raw-deref "
                 "qemu|rpi5|el0 AUDIT DEPFILE [--lower]")
    target, audit_path, depfile = args[0], Path(args[1]), Path(args[2])
    audit = read_raw_deref_audit(audit_path)
    budget = read_raw_deref_budget(RAW_DEREF_BUDGET)
    compiled = {
        Path(name).relative_to(REPO_ROOT).as_posix()
        if Path(name).is_absolute() else name
        for name in read_depfile_sources(depfile)}
    if lower:
        for line in lower_raw_deref_budget(RAW_DEREF_BUDGET, audit, compiled):
            print(f"lowered {line}")
        return 0
    problems = raw_deref_problems(
        audit, budget, compiled,
        # The compiler's built-in definitions (#672) are not a file on disk;
        # their row names them by the file name the compiler gives them.
        lambda name: name.startswith("<builtin ") or (REPO_ROOT / name).exists())
    for problem in problems:
        print(f"ERROR raw-deref-ratchet: {problem}")
    if problems:
        print(f"FAIL raw-deref-ratchet: {len(problems)} problem(s) in the "
              f"{target} build's raw-pointer dereferences")
        return 1
    report_pass(
        "raw-deref-ratchet",
        f"{target}: {sum(a[0] for a in audit.values())} plain and "
        f"{sum(a[1] for a in audit.values())} io dereference site(s) in "
        f"{len(audit)} file(s), checked across {len(compiled)} compiled source(s), "
        f"each equal to its recorded budget",
        files=len(compiled))
    return 0


def count_lines(paths: list[Path]) -> int:
    return sum(len(path.read_text().splitlines()) for path in paths)


def code_tokens(text: str) -> list[tuple[str, int, int]]:
    """Return code tokens while skipping lexer-equivalent comments/literals."""
    tokens = []
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if ch.isspace():
            i += 1
        elif ch == "/" and nxt == "/":
            newline = text.find("\n", i + 2)
            i = len(text) if newline < 0 else newline + 1
        elif ch == "/" and nxt == "*":
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 2
        elif ch in {'"', "'"}:
            start = i
            quote = ch
            i += 1
            while i < len(text):
                if text[i] == "\\":
                    i = min(i + 2, len(text))
                elif text[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
            tokens.append(("literal", start, i))
        elif ch.isalpha() or ch == "_":
            start = i
            i += 1
            while i < len(text) and (text[i].isalnum() or text[i] == "_"):
                i += 1
            tokens.append((text[start:i], start, i))
        else:
            tokens.append((ch, i, i + 1))
            i += 1
    return tokens


def unsafe_blocks(path: Path) -> list[tuple[int, str]]:
    """Return real unsafe-block line/body pairs from one lexical token pass."""
    text = path.read_text()
    tokens = code_tokens(text)
    result = []
    for index, (token, start, _) in enumerate(tokens):
        if token != "unsafe" or index + 1 >= len(tokens):
            continue
        if tokens[index + 1][0] != "{":
            continue
        depth = 0
        for closing in range(index + 1, len(tokens)):
            current = tokens[closing][0]
            if current == "{":
                depth += 1
            elif current == "}":
                depth -= 1
                if depth == 0:
                    end = tokens[closing][2]
                    result.append((text.count("\n", 0, start) + 1,
                                   text[start:end]))
                    break
        else:
            sys.exit(f"error: unterminated unsafe block in {path}")
    return result


def classify_unsafe(body: str) -> str:
    if ATOMIC_RE.search(body):
        return ATOMIC_CATEGORY
    if re.search(r"\bas\s+\*io\b", body):
        return "MMIO pointer construction/access"
    if re.search(r"\bas\s+\*", body):
        return "raw memory pointer/cast"
    if "[" in body:
        return "unchecked indexing/slice operation"
    return "unclassified"


def classify_raw_pointer_casts(paths: list[Path]) -> dict[str, int]:
    counts = {"total": 0, "device": 0, "string": 0, "memory": 0}
    for path in paths:
        text = path.read_text()
        for match in re.finditer(r"\bas\s+\*", text):
            counts["total"] += 1
            if text[match.end():match.end() + 3] == "io ":
                counts["device"] += 1
            elif text[:match.start()].rstrip().endswith('"'):
                counts["string"] += 1
            else:
                counts["memory"] += 1
    return counts


def classify_assembly() -> dict[str, list[Path]]:
    result = {"production handwritten": [], "generated": [], "fixture": []}
    paths = sorted(list(KERNEL_DIR.rglob("*.S")) + list(KERNEL_DIR.rglob("*.inc")))
    for path in paths:
        relative = path.relative_to(KERNEL_DIR)
        if "test" in relative.parts or "tests" in relative.parts:
            kind = "fixture"
        elif "GENERATED" in path.read_text()[:512]:
            kind = "generated"
        else:
            kind = "production handwritten"
        result[kind].append(path)
    return result


def count_pattern(paths: list[Path], pattern: str) -> int:
    regex = re.compile(pattern)
    return sum(len(regex.findall(path.read_text())) for path in paths)


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--check-raw-deref":
        sys.exit(check_raw_deref_main(sys.argv[2:]))
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true",
                        help="list exact sources and unsafe-site classifications")
    args = parser.parse_args()

    targets = {
        "RPi5 kernel": read_depfile_sources(KERNEL_DIR / "build/rpi5/main.o.d"),
        "QEMU kernel": read_depfile_sources(KERNEL_DIR / "build/qemu/main.o.d"),
        "EL0 test payload": read_depfile_sources(
            KERNEL_DIR / "build/rpi5/user_payload_tkb.o.d"
        ),
    }
    source_names = sorted(set().union(*map(set, targets.values())))
    source_paths = [REPO_ROOT / name for name in source_names]
    outside = sorted(set(KERNEL_DIR.rglob("*.tkb")) - set(source_paths))

    sites: dict[str, list[tuple[Path, int]]] = defaultdict(list)
    # How much code is inside them, not only how many there are. A block count
    # alone cannot tell "one block wrapping forty lines" from "eight blocks
    # wrapping one register access each", and those are opposite directions:
    # splitting one platform routine into named single-access primitives
    # RAISES the block count while lowering the amount of code the compiler
    # cannot check. Measured on 2026-09-09, when exactly that change added
    # eight blocks and no unchecked lines.
    body_lines: dict[str, int] = defaultdict(int)
    for path in source_paths:
        for line, body in unsafe_blocks(path):
            category = classify_unsafe(body)
            sites[category].append((path, line))
            body_lines[category] += body.count("\n") + 1
    atomic_files = {
        path.relative_to(KERNEL_DIR).as_posix()
        for path, _ in sites[ATOMIC_CATEGORY]
    }
    missing_allowlist = sorted(atomic_files - ATOMIC_ALLOWED.keys())
    unused_allowlist = sorted(ATOMIC_ALLOWED.keys() - atomic_files)
    raw_casts = classify_raw_pointer_casts(source_paths)
    assembly = classify_assembly()

    print("Takibi trusted-boundary inventory")
    print("=================================")
    print("Checked kernel source coverage")
    print(f"  --forbid-trap union : {len(source_paths)} files, {count_lines(source_paths)} lines")
    for target, names in targets.items():
        print(f"  {target:19}: {len(names)} files")
    print(f"  outside that union  : {len(outside)} kernel .tkb files")

    print("Explicit unsafe blocks (primary syntactic rationale)")
    categories = (
        ATOMIC_CATEGORY, "MMIO pointer construction/access",
        "raw memory pointer/cast", "unchecked indexing/slice operation",
        "unclassified",
    )
    for category in categories:
        print(f"  {category:36}: {len(sites[category]):4} blocks, "
              f"{body_lines[category]:5} lines")
    if missing_allowlist or unused_allowlist:
        print("  atomic ordering / RULE 2 allowlist: MISMATCH")
        for name in missing_allowlist:
            print(f"    classified atomic use is not allowlisted: {name}")
        for name in unused_allowlist:
            print(f"    allowlisted file has no classified atomic block: {name}")
    else:
        print(
            f"  atomic ordering / RULE 2 allowlist: agree "
            f"({len(atomic_files)} files)"
        )
    print(f"  {'total':36}: "
          f"{sum(len(sites[c]) for c in categories):4} blocks, "
          f"{sum(body_lines[c] for c in categories):5} lines")

    print("Other explicit source boundaries")
    print(f"  raw pointer casts                  : {raw_casts['total']}")
    print(f"    memory / MMIO / string           : {raw_casts['memory']} / {raw_casts['device']} / {raw_casts['string']}")
    print(f"  extern function/symbol declarations: {count_pattern(source_paths, r'\bextern\s+(?:fn|symbol)\b')}")
    dma_pattern = r"\b(?:dma_prepare_tx|dma_prepare_rx|dma_finish_rx|dma_publish|dma_consume)\s*\("
    print(f"  DMA/cache builtin operations       : {count_pattern(source_paths, dma_pattern)}")

    print("Assembly boundary")
    for category in ("production handwritten", "generated", "fixture"):
        paths = assembly[category]
        print(f"  {category:24}: {len(paths)} files, {count_lines(paths)} lines")

    if args.verbose:
        print("\nExact --forbid-trap source union")
        for name in source_names:
            print(f"  {name}")
        print("\nKernel .tkb files outside that union")
        for path in outside:
            print(f"  {path.relative_to(REPO_ROOT)}")
        print("\nUnsafe-site classifications")
        for category in sorted(sites):
            for path, line in sites[category]:
                print(f"  {category}: {path.relative_to(REPO_ROOT)}:{line}")

    if missing_allowlist or unused_allowlist:
        sys.exit("error: atomic trusted-base inventory disagrees with RULE 2 allowlist")


if __name__ == "__main__":
    main()
