#!/usr/bin/env python3
"""Keep the kernel's declared assembly entry points equal to what assembly calls.

GitHub issue #540. `--reject-unused-functions` sees only calls between Takibi
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
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"
BUILD = KERNEL / "build"

# The operand that names a symbol: a branch, an address formation, or a
# literal-pool load. Only names that are also Takibi functions count.
OPERAND = re.compile(
    r"^\s*(?:bl|b|adr|adrp|ldr)\s+(?:x[0-9]+,\s*)?=?([A-Za-z_][A-Za-z0-9_]*)",
    re.M)
FUNCTION = re.compile(r"^\s*(?:private\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
ENTRIES = re.compile(r"^KERNEL_ASM_ENTRIES\s*:=((?:.*\\\n)*.*)$", re.M)


def sources(suffix: str) -> list[Path]:
    return sorted(path for path in KERNEL.rglob(f"*{suffix}")
                  if BUILD not in path.parents)


def takibi_functions(texts: list[str]) -> set[str]:
    names = set()
    for text in texts:
        names.update(FUNCTION.findall(text))
    return names


def assembly_targets(texts: list[str], functions: set[str]) -> set[str]:
    return {name for text in texts for name in OPERAND.findall(text)
            if name in functions}


def makefile_entries(makefile: str) -> set[str] | None:
    match = ENTRIES.search(makefile)
    if match is None:
        return None
    return set(match.group(1).replace("\\\n", " ").split())


def problems(makefile: str, tkb: list[str], asm: list[str]) -> list[str]:
    declared = makefile_entries(makefile)
    if declared is None:
        return ["Makefile no longer defines KERNEL_ASM_ENTRIES"]
    targets = assembly_targets(asm, takibi_functions(tkb))
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


def main() -> int:
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    tkb = [path.read_text(errors="replace") for path in sources(".tkb")]
    asm = [path.read_text(errors="replace") for path in sources(".S")]
    found = problems(makefile, tkb, asm)
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
    if not problems(dropped, tkb, asm):
        print("ERROR kernel-asm-entries: dropping a declared entry passed")
        return 1
    added = makefile.replace("KERNEL_ASM_ENTRIES :=",
                             "KERNEL_ASM_ENTRIES := no_such_takibi_entry", 1)
    if not problems(added, tkb, asm):
        print("ERROR kernel-asm-entries: a stale declared entry passed")
        return 1

    report_pass("kernel-asm-entries",
                f"{len(declared)} Takibi functions named by kernel assembly "
                "are exactly the Makefile's declared entries, and both "
                "negative controls are refused",
                entries=len(declared), assembly_files=len(asm))
    return 0


if __name__ == "__main__":
    sys.exit(main())
