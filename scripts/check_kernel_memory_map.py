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

Four tables are machine-checked, each introduced by an HTML comment marker:

  <!-- checked: elf-symbols -->   symbol | RPi5 | QEMU | ... | State
      compared against `llvm-nm` output for both linked kernels.

  <!-- checked: elf-offsets -->   symbol | offset | ... | State
      the same comparison, against the symbol's distance from
      OFFSET_ANCHOR rather than its address, in one column for both
      platforms.  This is where most of the map lives, and why: an
      absolute address for a symbol that sits above `.bss` moves on
      almost every kernel commit, so recording twenty of them made this
      document conflict between any two people working at once -- 73 of
      the 76 commits that touched it moved a row.  Seventeen of those
      rows were a fixed shape riding on a moving base; as offsets they
      say the same thing and hold still.

  <!-- checked: elf-ceiling -->   span | ceiling | State
      the image must stay UNDER the recorded bound.  Not refreshed by
      --update, deliberately: with the floating boundaries no longer
      recorded, this is the row whose job is to make somebody look, and
      it should only move when a person decides the growth is ordinary.

  <!-- checked: consts -->        constant | value | file | State
      compared against `const NAME: <ty> = <literal>;` in the named file.

The boundaries that move every build -- __bss_start, __bss_end and the
stack block's base -- have no row at all.  check_layout_invariants reads
their ordering and alignment out of the build instead, so what those rows
used to pin incidentally is still pinned, on purpose.

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
QEMU_DEBUG_ELF = REPO / "kernel" / "build" / "qemu" / "kernel-debug.elf"
QEMU_RAM_END = 0x80000000
QEMU_LOW_RAM_END = 0x48000000
QEMU_HOLE_FIRST_END = 0x50000000
QEMU_HOLE_SECOND_START = 0x60000000
# The maintained board's firmware DTB leaves ordinary RAM below this address.
# A firmware/DTB change should fail here and require an explicit fixture audit.
RPI5_MANAGED_RAM_END = 0x3FC00000
PAGE_SIZE = 4096
# Every stack in this kernel is the upper half of a 32768-byte region aligned
# to 32768, which is what lets bit 14 of an address say which half it is in
# without loading a base. The block's own start has to hold that alignment or
# the generated exception entries report an overflow on every exception taken
# while standing on a stack.
STACK_REGION_BYTES = 0x8000
STACK_GUARD_SHIFT = 14
# Every offset row is measured from here, and the row for it must say +0.
OFFSET_ANCHOR = "boot_stack_run_bottom"
# The floating boundaries carry no row of their own; these are what still
# holds them, read from the build rather than from the document.
ORDERED_BOUNDARIES = ("_start", "__bss_start", "__bss_end", OFFSET_ANCHOR,
                      "usable_ram_start")
NM_CANDIDATES = ["llvm-nm-19", "llvm-nm", "nm"]


def fail(message):
    print(f"FAIL kernel/memory-map: {message}", file=sys.stderr)
    sys.exit(1)


def reject_conflict_markers(text):
    """An unresolved merge is not a document, and must not read as one.

    The parser below ends a table at the first line that is not a table
    row, which a conflict marker is.  A conflicted MEMORY_MAP.md therefore
    used to parse as a table of everything ABOVE the `<<<<<<<` -- one row,
    in the case that occurred -- and pass, while every row the conflict
    covered went unread.  The check that exists to keep this document
    honest reported it correct at the one moment it certainly was not.
    """
    for number, line in enumerate(text.splitlines(), start=1):
        if line.startswith(("<<<<<<<", ">>>>>>>", "|||||||")):
            fail(f"{DOC.name} line {number} is a merge conflict marker: "
                 f"{line.strip()!r}. Resolve the conflict first -- the rows "
                 f"a conflict covers are not checked, so a pass here would "
                 f"mean nothing")


def table_after(text, marker, state_tag):
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
    data = rows[1:]
    # The loop above stops at the first line that is not a table row, so
    # anything that interrupts the table hides every row below it. Silently,
    # because a shorter table is still a table. A row carrying this table's
    # state tag that the parser did not reach is a row claiming to be
    # verified while nothing reads it, which is the failure this whole file
    # argues against -- so count them and refuse to differ.
    claimed = sum(1 for line in text.splitlines()
                  if line.lstrip().startswith("|") and state_tag in line)
    if claimed != len(data):
        fail(f"{DOC.name} has {claimed} `{state_tag}` row(s) but the table "
             f"after `{marker}` holds {len(data)} of them; the rest sit "
             f"outside it, where nothing checks them")
    return data


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
            known = all(name in symbols[p] for p in ELFS)
            rewritten = None
            if (len(cells) >= 3 and any("CHECKED (ELF)" in c for c in cells)
                    and known):
                cells[1] = f"`0x{symbols['RPi5'][name]:08x}`"
                cells[2] = f"`0x{symbols['QEMU'][name]:08x}`"
                rewritten = cells
            elif (len(cells) >= 2
                    and any("CHECKED (ELF offset)" in c for c in cells)
                    and known):
                offsets = {symbols[p][name] - symbols[p][OFFSET_ANCHOR]
                           for p in ELFS}
                # Two platforms that no longer share the offset cannot be
                # stated in one column at all, so there is nothing to write.
                # Leaving the row is what makes the check say so.
                if len(offsets) == 1:
                    cells[1] = f"`+0x{offsets.pop():05x}`"
                    rewritten = cells
            # A CHECKED (ELF ceiling) row is never rewritten: it is the one
            # row that exists to be decided rather than derived.
            if rewritten is not None:
                indent = line[:len(line) - len(line.lstrip())]
                line = indent + "| " + " | ".join(rewritten) + " |\n"
        out.append(line)
    return "".join(out)


def check_elf_symbols(text, problems):
    marker = "<!-- checked: elf-symbols -->"
    symbols = {name: nm_symbols(elf) for name, elf in ELFS.items()}
    for cells in table_after(text, marker, "CHECKED (ELF)"):
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


def check_elf_offsets(text, problems):
    """The stack block, stated once as a shape instead of twice as addresses."""
    marker = "<!-- checked: elf-offsets -->"
    symbols = {name: nm_symbols(elf) for name, elf in ELFS.items()}
    for platform in ELFS:
        if OFFSET_ANCHOR not in symbols[platform]:
            fail(f"{OFFSET_ANCHOR}, which every offset row is measured from, "
                 f"is absent from the {platform} build")
    rows = table_after(text, marker, "CHECKED (ELF offset)")
    anchor_row = unbacktick(rows[0][0])
    if anchor_row != OFFSET_ANCHOR:
        fail(f"the `{marker}` table must open with `{OFFSET_ANCHOR}`, the "
             f"anchor its offsets are measured from; it opens with "
             f"`{anchor_row}`")
    for cells in rows:
        if len(cells) < 2:
            fail(f"malformed row in the `{marker}` table: {cells}")
        symbol = unbacktick(cells[0])
        check_state(cells, marker, symbol)
        documented = parse_int(cells[1])
        if documented is None:
            fail(f"`{symbol}`'s offset cell is not a number: {cells[1]!r}")
        actual = {}
        for platform in ELFS:
            if symbol not in symbols[platform]:
                problems.append(f"`{symbol}` is documented but absent from "
                                f"the {platform} build")
                continue
            actual[platform] = (symbols[platform][symbol]
                                - symbols[platform][OFFSET_ANCHOR])
        if len(set(actual.values())) > 1:
            # The single column is a claim about both platforms. When it
            # stops being true the answer is not a wider table by default:
            # the linker scripts diverging here is a fact somebody has to
            # decide about.
            shown = ", ".join(f"{p} +0x{o:x}" for p, o in sorted(actual.items()))
            problems.append(
                f"`{symbol}` is at a different offset on each platform "
                f"({shown}), so the shared-shape column can no longer state "
                f"it -- decide whether the linker scripts should diverge here")
            continue
        for platform, offset in actual.items():
            if offset != documented:
                problems.append(
                    f"`{symbol}` on {platform}: document says "
                    f"{OFFSET_ANCHOR}+0x{documented:x}, build says "
                    f"{OFFSET_ANCHOR}+0x{offset:x}")


def check_image_ceiling(text, problems):
    """A bound the image must stay under, and the row --update will not move."""
    marker = "<!-- checked: elf-ceiling -->"
    symbols = {name: nm_symbols(elf) for name, elf in ELFS.items()}
    rows = table_after(text, marker, "CHECKED (ELF ceiling)")
    if len(rows) != 1:
        fail(f"the `{marker}` table must hold exactly one row, the image "
             f"ceiling; it holds {len(rows)}")
    cells = rows[0]
    if len(cells) < 2:
        fail(f"malformed row in the `{marker}` table: {cells}")
    check_state(cells, marker, "the image ceiling")
    ceiling = parse_int(cells[1])
    if ceiling is None:
        fail(f"the image ceiling is not a number: {cells[1]!r}")
    for platform in ELFS:
        for symbol in ("_start", "usable_ram_start"):
            if symbol not in symbols[platform]:
                fail(f"{symbol} is absent from the {platform} build")
        size = (symbols[platform]["usable_ram_start"]
                - symbols[platform]["_start"])
        if size >= ceiling:
            problems.append(
                f"{platform}: the kernel image is 0x{size:x} bytes "
                f"({size / 1048576:.2f} MiB) and reached the recorded ceiling "
                f"of 0x{ceiling:x} ({ceiling / 1048576:.2f} MiB). This is the "
                f"row --update will not raise for you: ordinary growth is "
                f"expected to arrive here eventually, so decide that it is "
                f"ordinary, then raise it by hand")


def check_layout_invariants(problems):
    """What holds the boundaries whose absolute address is not recorded.

    Dropping their rows is what stopped this document conflicting on every
    kernel commit (see its own "Physical layout" section). It is only a
    trade rather than a loss because the properties those rows used to pin
    incidentally are pinned here on purpose.
    """
    symbols = {name: nm_symbols(elf) for name, elf in ELFS.items()}
    for platform in ELFS:
        found = symbols[platform]
        missing = [s for s in ORDERED_BOUNDARIES if s not in found]
        if missing:
            fail(f"the {platform} build is missing {', '.join(missing)}")
        values = [found[s] for s in ORDERED_BOUNDARIES]
        if not (values[0] < values[1] <= values[2] <= values[3] < values[4]):
            shown = ", ".join(f"{s} 0x{found[s]:x}" for s in ORDERED_BOUNDARIES)
            problems.append(f"{platform}: the image is out of order -- {shown}")
        for symbol in ("__bss_start", "usable_ram_start"):
            if found[symbol] % PAGE_SIZE != 0:
                problems.append(
                    f"{platform}: {symbol} 0x{found[symbol]:x} is not "
                    f"page-aligned")
        if found[OFFSET_ANCHOR] % STACK_REGION_BYTES != 0:
            problems.append(
                f"{platform}: {OFFSET_ANCHOR} 0x{found[OFFSET_ANCHOR]:x} is "
                f"not 0x{STACK_REGION_BYTES:x}-aligned, so bit "
                f"{STACK_GUARD_SHIFT} no longer says which half of a stack "
                f"region an address is in")


def check_consts(text, problems):
    marker = "<!-- checked: consts -->"
    sources = {}
    for cells in table_after(text, marker, "CHECKED (const)"):
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


def expected_boot_pages(path):
    text = path.read_text()
    matches = re.findall(r"^memory: .* allocator_pages=(\d+)$",
                         text, re.MULTILINE)
    if len(matches) != 1:
        fail(f"{path.relative_to(REPO)} must contain exactly one memory line "
             "with allocator_pages")
    return int(matches[0])


def expected_python_pages(path, name):
    text = path.read_text()
    match = re.search(
        rf"^{re.escape(name)}\s*=\s*\((.*?)\)\s*$",
        text, re.MULTILINE | re.DOTALL)
    if match is None:
        fail(f"{path.relative_to(REPO)} has no {name} tuple")
    pages = re.findall(r"allocator_pages=(\d+)", match.group(1))
    if len(pages) != 1:
        fail(f"{name} in {path.relative_to(REPO)} must contain exactly one "
             "allocator_pages value")
    return int(pages[0])


def page_span(start, end, label):
    if start % PAGE_SIZE != 0 or end % PAGE_SIZE != 0 or start >= end:
        fail(f"{label} is not a non-empty page-aligned span")
    return (end - start) // PAGE_SIZE


def check_allocator_expectations(problems, include_debug):
    symbols = {name: nm_symbols(elf) for name, elf in ELFS.items()}
    starts = {}
    for platform in ("RPi5", "QEMU"):
        start = symbols[platform].get("usable_ram_start")
        if start is None:
            fail(f"usable_ram_start is absent from the {platform} build")
        starts[platform] = start

    expected = {
        "kernel/tests/qemu/views/boot.expected":
            page_span(starts["QEMU"], QEMU_RAM_END, "QEMU managed RAM"),
        "kernel/tests/rpi5/views/boot.expected":
            page_span(starts["RPi5"], RPI5_MANAGED_RAM_END,
                      "RPi5 managed RAM"),
    }
    for relative, actual in expected.items():
        documented = expected_boot_pages(REPO / relative)
        if documented != actual:
            problems.append(
                f"`{relative}` says allocator_pages={documented}, "
                f"linked layout requires {actual}")

    fdt_path = REPO / "kernel/tests/check_fdt_multibank_qemu.py"
    fdt_expected = {
        "MULTIBANK_EXPECTED":
            page_span(starts["QEMU"], QEMU_RAM_END, "QEMU multi-bank RAM"),
        "LOW_MEMORY_EXPECTED":
            page_span(starts["QEMU"], QEMU_LOW_RAM_END, "QEMU low RAM"),
        "DISCONTIGUOUS_MEMORY_EXPECTED":
            page_span(starts["QEMU"], QEMU_HOLE_FIRST_END,
                      "QEMU first discontiguous extent") +
            page_span(QEMU_HOLE_SECOND_START, QEMU_RAM_END,
                      "QEMU second discontiguous extent"),
    }
    for name, actual in fdt_expected.items():
        documented = expected_python_pages(fdt_path, name)
        if documented != actual:
            problems.append(
                f"`{name}` says allocator_pages={documented}, "
                f"linked layout requires {actual}")

    if include_debug:
        debug_start = nm_symbols(QEMU_DEBUG_ELF).get("usable_ram_start")
        if debug_start is None:
            fail("usable_ram_start is absent from the QEMU debug build")
        actual = page_span(debug_start, QEMU_RAM_END,
                           "QEMU debug managed RAM")
        relative = "kernel/tests/qemu-debug/views/boot.expected"
        documented = expected_boot_pages(REPO / relative)
        if documented != actual:
            problems.append(
                f"`{relative}` says allocator_pages={documented}, "
                f"linked layout requires {actual}")


def main():
    if not DOC.exists():
        fail(f"{DOC} does not exist")
    text = DOC.read_text()
    # Before --update, too: refreshing rows around a conflict marker would
    # rewrite one side of the conflict and leave the document unresolved.
    reject_conflict_markers(text)
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
    check_elf_offsets(text, problems)
    check_image_ceiling(text, problems)
    check_layout_invariants(problems)
    check_consts(text, problems)
    check_allocator_expectations(problems, "--debug" in sys.argv[1:])
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        # Name the maintenance action in the failure, the way
        # effect-matrix-control names --emit-effect-matrix and
        # check_agents_paths.py names the table to edit. This script had the
        # --update flag documented only in its own docstring, which is the
        # one place nobody reads while a build is red: four separate
        # hand-edits of these rows happened in one session before anybody
        # noticed the flag existed.
        #
        # Worded to keep the order the docstring argues for. The check exists
        # so somebody LOOKS at a layout change; --update is what you run
        # AFTER deciding the move is intended, not instead of deciding.
        print("  Decide first whether this layout move is intended -- a "
              "section that MOVED with its size unchanged is ordinary code "
              "growth ahead of it, a section that GREW is new state. Then "
              "refresh the rows with:", file=sys.stderr)
        print("      python3 scripts/check_kernel_memory_map.py --update",
              file=sys.stderr)
        print("  That refreshes every checked row except the image ceiling, "
              "which is left for you on purpose: reaching it is the one "
              "layout event this document still asks a person to look at.",
              file=sys.stderr)
        fail(f"{len(problems)} row(s) disagree with the build")
    suffix = ", including the debug image" if "--debug" in sys.argv[1:] else ""
    print("PASS kernel/memory-map: checked rows and allocator expectations "
          f"match the linked kernels{suffix}")


if __name__ == "__main__":
    main()
