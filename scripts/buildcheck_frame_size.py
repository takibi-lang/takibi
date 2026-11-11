#!/usr/bin/env python3
"""Refuse a kernel function whose stack frame exceeds a ceiling (GitHub issue #1081).

Every kernel stack is 16 KiB (the boot stack, every process stack). The
first #1081 design carried 520 more bytes in an ELF load plan that is
passed by value, and each copy is a stack temporary: frames along the exec
path grew from under 1 KiB to 3.6-6.5 KiB, and the boot stack overflowed in
the debug images. No check before QEMU saw it.

Read LLVM .stack_sizes for every defined STT_FUNC in an AArch64 kernel
object. The compiler's module-level assembly entry labels are STT_NOTYPE
and stay outside this check, as do the separately assembled objects.
LLVM's static frame sizes cover single functions, not call paths or stack
effects of assembly. An ordinary function without a record is an error.

Usage: buildcheck_frame_size.py OBJECT...
"""
import struct
import sys
from collections import defaultdict
from pathlib import Path
from typing import NamedTuple

from pass_line import report_pass

CEILING = 2048

# Existing exceptions, with their full frame in the largest image measured
# (the debug images) and why each is accepted. The #1496 correction includes
# the 96-byte stp allocation omitted from both records by the old parser,
# measured against the already accepted c37c938b objects; it accepts no
# physical frame growth. Lower an entry when its frame shrinks; delete it
# at or under the ceiling.
BUDGET = {
    # Boot-only scheduler probe, run once on the boot stack early in boot.
    "kernel_process_scheduler_probe": 3312,
    # ext2 write path; runs on a process stack with a shallow caller chain.
    "ext2_update_regular_file": 2640,
}

# The object format emitted by LLVM for aarch64-none-elf.
ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
SECTION_HEADER = struct.Struct("<IIQQQQIIQQ")
SYMBOL = struct.Struct("<IBBHQQ")
RELA = struct.Struct("<QQq")
SHT_PROGBITS, SHT_SYMTAB, SHT_STRTAB, SHT_RELA = 1, 2, 3, 4
SHF_EXECINSTR, SHF_LINK_ORDER = 4, 128
STT_FUNC, STT_SECTION = 2, 3
R_AARCH64_ABS64 = 257


class Section(NamedTuple):
    name_offset: int
    kind: int
    flags: int
    address: int
    offset: int
    size: int
    link: int
    info: int
    align: int
    entry_size: int


def string_at(table, offset):
    end = table.find(b"\0", offset)
    if end < 0:
        raise ValueError("malformed ELF string table")
    return table[offset:end].decode("ascii")


def stack_size(data, offset):
    """Decode the unsigned 64-bit ULEB128 following a relocated address."""
    size = 0
    for shift in range(0, 64, 7):
        if offset == len(data):
            break
        byte = data[offset]
        offset += 1
        size |= (byte & 127) << shift
        if byte < 128:
            if size < 1 << 64 and (shift == 0 or byte != 0):
                return size, offset
            break
    raise ValueError("malformed .stack_sizes ULEB128")


def stack_records(data, relocations, symbols):
    # Each address field is zero before relocation and each record must
    # have exactly one relocation. Also account for bytes after the final
    # relocation, which llvm-readobj's stack-size printer skips.
    cursor = 0
    for offset, info, addend in sorted(relocations):
        if offset != cursor or offset + 8 >= len(data) or any(data[offset:offset + 8]):
            raise ValueError("malformed .stack_sizes record layout")
        index, kind = info >> 32, info & 0xffffffff
        if kind != R_AARCH64_ABS64 or index >= len(symbols):
            raise ValueError("malformed .stack_sizes relocation")
        _, info, _, section, value, _ = symbols[index]
        if info & 15 not in (STT_FUNC, STT_SECTION):
            raise ValueError("malformed .stack_sizes relocation symbol")
        size, cursor = stack_size(data, offset + 8)
        yield (section, value + addend), size
    if cursor != len(data):
        raise ValueError("unrelocated bytes in .stack_sizes")


def frames(data):
    """Map defined function names to LLVM's static frame sizes."""
    ident, kind, machine, version, _, _, shoff, _, _, _, _, shsize, count, names = (
        ELF_HEADER.unpack_from(data)
    )
    if (ident[:7] != b"\x7fELF\x02\x01\x01" or
            (kind, machine, version) != (1, 183, 1)):
        raise ValueError("expected an AArch64 ELF64 little-endian relocatable object")
    if shsize != SECTION_HEADER.size or not 0 < names < count:
        raise ValueError("malformed ELF section table")
    sections = [Section(*SECTION_HEADER.unpack_from(data, shoff + i * shsize))
                for i in range(count)]

    def contents(section):
        end = section.offset + section.size
        if end > len(data):
            raise ValueError("truncated ELF section")
        return data[section.offset:end]

    if sections[names].kind != SHT_STRTAB:
        raise ValueError("malformed ELF section name table")
    section_names = contents(sections[names])
    stack_sections = [i for i, section in enumerate(sections)
                      if string_at(section_names, section.name_offset) == ".stack_sizes"]
    if not stack_sections:
        raise ValueError("missing .stack_sizes section")

    tables = [i for i, section in enumerate(sections) if section.kind == SHT_SYMTAB]
    if len(tables) != 1:
        raise ValueError("expected one ELF symbol table")
    table = sections[tables[0]]
    if (table.entry_size != SYMBOL.size or not 0 < table.link < count or
            sections[table.link].kind != SHT_STRTAB):
        raise ValueError("malformed ELF symbol table")
    symbols = list(SYMBOL.iter_unpack(contents(table)))
    symbol_names = contents(sections[table.link])
    functions = defaultdict(list)
    names_seen = set()
    for name_offset, info, _, section, address, _ in symbols:
        if info & 15 != STT_FUNC or section == 0:
            continue
        name = string_at(symbol_names, name_offset)
        if (not name or section >= count or not sections[section].flags & SHF_EXECINSTR
                or address >= sections[section].size):
            raise ValueError(f"{name}: malformed defined ELF function")
        if name in names_seen:
            raise ValueError(f"{name}: duplicate ELF function name")
        names_seen.add(name)
        functions[section, address].append(name)
    if not functions:
        raise ValueError("no ELF functions found")

    by_target = defaultdict(list)
    for section in sections:
        if section.kind == SHT_RELA:
            by_target[section.info].append(section)

    measured = {}
    for index in stack_sections:
        section = sections[index]
        if (section.kind != SHT_PROGBITS or section.flags != SHF_LINK_ORDER or
                not 0 < section.link < count or not section.size):
            raise ValueError("malformed .stack_sizes section")
        relocations = by_target[index]
        if len(relocations) != 1:
            raise ValueError("expected one relocation section for .stack_sizes")
        reloc = relocations[0]
        if reloc.link != tables[0] or reloc.entry_size != RELA.size:
            raise ValueError("malformed .stack_sizes relocation section")
        # SHF_LINK_ORDER controls link placement. LLVM 19 can link this
        # section to .rodata after emitting a jump table. The relocation
        # itself identifies the function, even for that object shape.
        for key, size in stack_records(contents(section),
                                       RELA.iter_unpack(contents(reloc)),
                                       symbols):
            if key not in functions:
                target_section, address = key
                raise ValueError("unknown function address in .stack_sizes "
                                 f"(section {target_section}, offset {address:#x})")
            for name in functions[key]:
                if name in measured:
                    raise ValueError(f"{name}: duplicate .stack_sizes record")
                measured[name] = size

    missing = names_seen - measured.keys()
    if missing:
        raise ValueError("missing .stack_sizes record for " + ", ".join(sorted(missing)))
    return measured


def problems(measured, budget=BUDGET, ceiling=CEILING):
    out = []
    for name, size in sorted(measured.items()):
        limit = budget.get(name, ceiling)
        if size > limit:
            if name in budget:
                out.append(f"{name}: frame {size} B exceeds its recorded budget "
                           f"{limit} B")
            else:
                out.append(f"{name}: frame {size} B exceeds the {ceiling} B ceiling "
                           f"(a large value passed or held by value? see #1081)")
    for name in sorted(budget):
        if name not in measured:
            out.append(f"{name}: budget entry for a function not in the image")
        elif measured[name] <= ceiling:
            out.append(f"{name}: frame {measured[name]} B is within the ceiling; "
                       f"delete its budget entry")
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    failed = False
    for path in argv[1:]:
        try:
            measured = frames(Path(path).read_bytes())
        except (OSError, ValueError, struct.error) as error:
            print(f"FAIL frame-size: {path}: {error}", file=sys.stderr)
            failed = True
            continue
        # A target that lacks an exception does not make its budget stale.
        active_budget = {name: BUDGET[name] for name in BUDGET.keys() & measured.keys()}
        found = problems(measured, budget=active_budget)
        if found:
            failed = True
            for p in found:
                print(f"FAIL frame-size: {path}: {p}", file=sys.stderr)
        else:
            largest = max(measured.items(), key=lambda kv: kv[1])
            report_pass("frame-size",
                        f"{path}: {len(measured)} functions, largest "
                        f"{largest[0]} {largest[1]} B, ceiling {CEILING} B, "
                        f"{len(active_budget)} budgeted",
                        functions=len(measured))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
