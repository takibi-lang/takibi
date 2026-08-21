#!/usr/bin/env python3
"""Fail the build when kernel/MEMORY_MAP.md and the build disagree.

Run with --update to rewrite the ELF-symbol rows from the current build
instead of failing. That is the maintenance action after a change that
moves the layout, and it is deliberately a separate command rather than
something the check does for you: the point of the check is that somebody
LOOKS at a layout change, and a self-healing document is one nobody
reads.

A memory map is the kind of document that is written once, is correct for a
month, and is then quietly wrong at the moment someone trusts it.  The rows
it can check are checked; the rows it cannot are required to say so, which
is the other half of the same guarantee -- silence about which is which is
the failure mode.

Two tables are machine-checked, each introduced by an HTML comment marker:

  <!-- checked: elf-symbols -->   symbol | RPi5 | QEMU | ... | State
      compared against `llvm-nm` output for both linked kernels.

  <!-- checked: consts -->        constant | value | file | State
      compared against `const NAME: <ty> = <literal>;` in the named file.

Rows in those tables must be marked `CHECKED`.  A row that is not is a row
claiming to be verified while nothing verifies it, which is worse than an
honest HAND row, so it is an error.
"""

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DOC = REPO / "kernel" / "MEMORY_MAP.md"
ELFS = {
    "RPi5": REPO / "kernel" / "build" / "rpi5" / "kernel.elf",
    "QEMU": REPO / "kernel" / "build" / "qemu" / "kernel.elf",
}
NM_CANDIDATES = ["llvm-nm-19", "llvm-nm", "nm"]


def fail(message):
    print(f"FAIL kernel/memory-map: {message}", file=sys.stderr)
    sys.exit(1)


def table_after(text, marker):
    """The contiguous markdown table following `marker`, as a list of cell lists."""
    start = text.find(marker)
    if start < 0:
        fail(f"{DOC.name} has no `{marker}` marker; the checked table is gone "
             f"or was renamed, so nothing is being verified")
    rows = []
    for line in text[start + len(marker):].splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            if rows:
                break
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if all(set(c) <= set("-: ") for c in cells):
            continue
        rows.append(cells)
    if len(rows) < 2:
        fail(f"the table after `{marker}` has no data rows")
    return rows[1:]


def unbacktick(cell):
    return cell.strip().strip("`").strip()


def parse_int(cell):
    value = unbacktick(cell).replace("_", "")
    try:
        return int(value, 0)
    except ValueError:
        return None


def nm_symbols(elf):
    if not elf.exists():
        fail(f"{elf} does not exist -- build both kernels before checking the map")
    for tool in NM_CANDIDATES:
        try:
            out = subprocess.run([tool, str(elf)], capture_output=True, text=True,
                                 check=True).stdout
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
        symbols = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 3:
                symbols[parts[2]] = int(parts[0], 16)
        return symbols
    fail("no usable nm found (tried: " + ", ".join(NM_CANDIDATES) + ")")


def check_state(cells, marker, name):
    if not any("CHECKED" in c for c in cells):
        fail(f"row `{name}` in the `{marker}` table is not marked CHECKED. "
             f"Rows in a checked table must say so; move it to a HAND table "
             f"if nothing verifies it")


def update_elf_symbols(text):
    """Rewrite the ELF rows from the build. Returns the new document text."""
    marker = "<!-- checked: elf-symbols -->"
    symbols = {name: nm_symbols(elf) for name, elf in ELFS.items()}
    out = []
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("|") and not all(
                set(c) <= set("-: ") for c in stripped.strip("|").split("|")):
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            name = unbacktick(cells[0])
            if (len(cells) >= 3 and any("CHECKED (ELF)" in c for c in cells)
                    and name in symbols["RPi5"] and name in symbols["QEMU"]):
                cells[1] = f"`0x{symbols['RPi5'][name]:08x}`"
                cells[2] = f"`0x{symbols['QEMU'][name]:08x}`"
                indent = line[:len(line) - len(line.lstrip())]
                line = indent + "| " + " | ".join(cells) + " |\n"
        out.append(line)
    return "".join(out)


def check_elf_symbols(text, problems):
    marker = "<!-- checked: elf-symbols -->"
    symbols = {name: nm_symbols(elf) for name, elf in ELFS.items()}
    for cells in table_after(text, marker):
        if len(cells) < 3:
            fail(f"malformed row in the `{marker}` table: {cells}")
        symbol = unbacktick(cells[0])
        check_state(cells, marker, symbol)
        for column, platform in enumerate(("RPi5", "QEMU"), start=1):
            documented = parse_int(cells[column])
            if documented is None:
                fail(f"`{symbol}`'s {platform} cell is not a number: {cells[column]!r}")
            actual = symbols[platform].get(symbol)
            if actual is None:
                problems.append(
                    f"`{symbol}` is documented but absent from the {platform} build")
            elif actual != documented:
                problems.append(
                    f"`{symbol}` on {platform}: document says 0x{documented:08x}, "
                    f"build says 0x{actual:08x}")


def check_consts(text, problems):
    marker = "<!-- checked: consts -->"
    sources = {}
    for cells in table_after(text, marker):
        if len(cells) < 3:
            fail(f"malformed row in the `{marker}` table: {cells}")
        name = unbacktick(cells[0])
        check_state(cells, marker, name)
        documented = parse_int(cells[1])
        if documented is None:
            fail(f"`{name}`'s value cell is not a number: {cells[1]!r}")
        path = REPO / unbacktick(cells[2])
        if path not in sources:
            if not path.exists():
                fail(f"`{name}` names {path}, which does not exist")
            sources[path] = path.read_text()
        # Only bare-literal consts are checkable this way; a derived one
        # (`A * B`) belongs in the document's HAND table instead, so not
        # finding a literal here is an error rather than a skip.
        match = re.search(
            rf"^\s*const\s+{re.escape(name)}\s*:\s*\w+\s*=\s*([0-9][0-9a-fA-FxX_]*)\s*;",
            sources[path], re.MULTILINE)
        if match is None:
            problems.append(
                f"`{name}` is not a bare-literal const in {unbacktick(cells[2])} -- "
                f"either it moved, or it became derived and the row belongs in "
                f"the hand-maintained table")
            continue
        actual = int(match.group(1).replace("_", ""), 0)
        if actual != documented:
            problems.append(
                f"`{name}`: document says {documented}, "
                f"{unbacktick(cells[2])} says {actual}")


def main():
    if not DOC.exists():
        fail(f"{DOC} does not exist")
    text = DOC.read_text()
    if "--update" in sys.argv[1:]:
        updated = update_elf_symbols(text)
        DOC.write_text(updated)
        if updated == text:
            print("kernel/memory-map: no ELF row needed updating")
        else:
            print("kernel/memory-map: ELF rows refreshed from the current build")
        text = updated
    problems = []
    check_elf_symbols(text, problems)
    check_consts(text, problems)
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        fail(f"{len(problems)} row(s) disagree with the build")
    print("PASS kernel/memory-map: every checked row in kernel/MEMORY_MAP.md "
          "matches the linked kernels and their constants")


if __name__ == "__main__":
    main()
