#!/usr/bin/env python3
"""Keep the kernel's declared assembly entry points equal to what assembly calls.

GitHub issue #540. The unused-function check sees only calls between Takibi
functions. A function that kernel assembly reaches by name -- `bl
kernel_syscall_dispatch` in user_entry.S -- has no Takibi caller, so the
Makefile declares it with `--external-entry`. A hand-written list drifts both
ways. A new branch target missing from it makes the whole call tree below it
look dead. A name left behind after the assembly stops calling it keeps a dead
function alive. This derives the set from the `.S` files and compares it with
the Makefile's KERNEL_ASM_ENTRIES.
"""

import re
import sys
import tempfile
from pathlib import Path

from buildcheck_frame_api import read_signatures
from pass_line import report_pass
from source_scan import function_header

ROOT = Path(__file__).resolve().parent.parent

# The operand that names a symbol: a branch, an address formation, or a
# literal-pool load. Only names that are also Takibi functions count.
OPERAND = re.compile(
    r"^\s*(?:bl|b|adr|adrp|ldr)\s+(?:x[0-9]+,\s*)?=?([A-Za-z_][A-Za-z0-9_]*)",
    re.M)
FUNCTION = function_header()
ENTRIES = re.compile(r"^KERNEL_ASM_ENTRIES\s*:=((?:.*\\\n)*.*)$", re.M)


# A standalone QEMU fixture with its own entry and link (GitHub issue #713);
# it is never linked into either kernel, so its entry is not a kernel one.
STANDALONE = Path("kernel/tests/debug_return_abi")


def sources(root: Path, suffix: str) -> list[Path]:
    kernel = root / "kernel"
    return sorted(path for path in kernel.rglob(f"*{suffix}")
                  if kernel / "build" not in path.parents
                  and root / STANDALONE not in path.parents)


def takibi_functions(root: Path, signatures) -> set[str]:
    by_file: dict[str, set[str]] = {}
    for relative, name, _, _ in signatures:
        by_file.setdefault(relative, set()).add(name)

    functions = set()
    for path in sources(root, ".tkb"):
        names = by_file.get(path.relative_to(root).as_posix())
        if names is None:
            # Standalone programs and fixtures may be outside both normal
            # kernel closures. Keep the old source check for those files.
            names = FUNCTION.findall(path.read_text(errors="replace"))
        functions.update(names)
    return functions


def assembly_targets(texts: list[str], functions: set[str]) -> set[str]:
    return {name for text in texts for name in OPERAND.findall(text)
            if name in functions}


def makefile_entries(makefile: str) -> set[str] | None:
    match = ENTRIES.search(makefile)
    if match is None:
        return None
    return set(match.group(1).replace("\\\n", " ").split())


def problems(makefile: str, functions: set[str], asm: list[str]) -> list[str]:
    declared = makefile_entries(makefile)
    if declared is None:
        return ["Makefile no longer defines KERNEL_ASM_ENTRIES"]
    targets = assembly_targets(asm, functions)
    result = []
    for name in sorted(targets - declared):
        result.append(f"kernel assembly calls {name} by name, and "
                      "KERNEL_ASM_ENTRIES does not declare it, so everything "
                      "only it reaches would be reported unused")
    for name in sorted(declared - targets):
        result.append(f"KERNEL_ASM_ENTRIES declares {name}, and no kernel "
                      "assembly names it, so it could keep a dead function "
                      "alive")
    return result


def inventory_controls():
    # The covered file need not supply a readable function definition here.
    # The uncovered file does, and a standalone source/fact must stay out.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        kernel = root / "kernel"
        standalone = root / STANDALONE
        standalone.mkdir(parents=True)
        (kernel / "covered.tkb").write_text("", encoding="ascii")
        (kernel / "uncovered.tkb").write_text(
            "fn uncovered_target() {}\n", encoding="ascii")
        (standalone / "standalone.tkb").write_text(
            "fn standalone_target() {}\n", encoding="ascii")
        signatures = [
            ("kernel/covered.tkb", "covered_target", False, "void"),
            ((STANDALONE / "standalone.tkb").as_posix(),
             "standalone_target", False, "void"),
        ]
        return takibi_functions(root, signatures) == {"covered_target", "uncovered_target"}


def main(argv) -> int:
    if len(argv) not in (0, 2):
        sys.exit("usage: buildcheck_kernel_asm_entries.py [QEMU_SIGNATURES RPI5_SIGNATURES]")
    signatures = []
    for path in argv:
        rows = list(read_signatures(path))
        if not rows:
            raise ValueError(f"{path}: no source signatures")
        signatures.extend(rows)

    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    functions = takibi_functions(ROOT, signatures)
    asm = [path.read_text(errors="replace") for path in sources(ROOT, ".S")]
    found = problems(makefile, functions, asm)
    if found:
        for problem in found:
            print(f"ERROR kernel-asm-entries: {problem}")
        return 1

    # Negative controls: the comparison has to notice both directions.
    declared = sorted(makefile_entries(makefile) or ())
    if not declared:
        print("ERROR kernel-asm-entries: KERNEL_ASM_ENTRIES is empty")
        return 1
    block = ENTRIES.search(makefile).group(0)
    dropped = makefile.replace(
        block, re.sub(rf"\b{re.escape(declared[0])}\b", "", block, count=1), 1)
    if not problems(dropped, functions, asm):
        print("ERROR kernel-asm-entries: dropping a declared entry passed")
        return 1
    added = makefile.replace("KERNEL_ASM_ENTRIES :=",
                             "KERNEL_ASM_ENTRIES := no_such_takibi_entry", 1)
    if not problems(added, functions, asm):
        print("ERROR kernel-asm-entries: a stale declared entry passed")
        return 1

    if not inventory_controls():
        print("ERROR kernel-asm-entries: source inventory controls failed")
        return 1

    report_pass("kernel-asm-entries",
                f"{len(declared)} Takibi functions named by kernel assembly "
                "are exactly the Makefile's declared entries; "
                "entry and inventory controls passed",
                entries=len(declared), assembly_files=len(asm))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        sys.exit(f"ERROR kernel-asm-entries: {error}")
