#!/usr/bin/env python3
"""Check real AArch64 objects and corruptions of their frame records."""
import struct
import sys
from pathlib import Path

from buildcheck_frame_size import (ELF_HEADER, RELA, SECTION_HEADER, Section,
                                   frames, problems, string_at)
from pass_line import report_pass


def fixture(name):
    path = Path(__file__).with_name("fixtures") / f"frame-{name}.elf.hex"
    return bytes.fromhex("".join(line for line in path.read_text().splitlines()
                                 if not line.startswith("#")))


def section_location(obj, name):
    shoff, shsize, count, names = (ELF_HEADER.unpack_from(obj)[i]
                                  for i in (6, 11, 12, 13))
    offsets = range(shoff, shoff + shsize * count, shsize)
    sections = [Section(*SECTION_HEADER.unpack_from(obj, at)) for at in offsets]
    names = sections[names]
    strings = obj[names.offset:names.offset + names.size]
    return next((at, sec) for at, sec in zip(offsets, sections)
                if string_at(strings, sec.name_offset) == name)


def replaced(obj, fmt, offset, *values):
    data = bytearray(obj)
    struct.pack_into(fmt, data, offset, *values)
    return data


def rejected(obj, diagnostic):
    try:
        frames(obj)
    except (ValueError, struct.error) as error:
        return diagnostic in str(error)
    return False


def main():
    # The compiler witness allocates its 2096 bytes after 16 nops and a
    # branch. The other object has mutually exclusive 1536-byte allocations
    # and a separate, untyped assembly entry with no metadata.
    measured_late = frames(fixture("late"))
    late = {"meta_large": measured_late["meta_large"]}
    exclusive = fixture("exclusive")
    small = frames(exclusive)
    section_at, section = section_location(exclusive, ".stack_sizes")
    reloc_at, reloc = section_location(exclusive, ".rela.stack_sizes")
    first = RELA.unpack_from(exclusive, reloc.offset)
    second = RELA.unpack_from(exclusive, reloc.offset + RELA.size)

    # Remove the second record and its relocation together. The remaining
    # bytes and relocation are internally valid but omit the ordinary leaf.
    missing = replaced(exclusive, "<Q", section_at + 32, second[0])
    missing = replaced(missing, "<Q", reloc_at + 32, RELA.size)

    duplicate = replaced(exclusive, "<QQq", reloc.offset + RELA.size,
                         second[0], first[1], first[2])
    unknown = replaced(exclusive, "<q", reloc.offset + 16, first[2] + 4)
    malformed = replaced(exclusive, "<B", section.offset + section.size - 1, 0x80)
    unsupported = replaced(exclusive, "<I", reloc.offset + 8, 0)
    unrelocated = replaced(exclusive, "<Q", reloc_at + 32, RELA.size)

    checks = {
        "late frame crosses the ceiling":
            late == {"meta_large": 2096}
            and any("frame 2096 B exceeds the 2048 B ceiling" in p
                    for p in problems(late, budget={})),
        "late small frame passes and combined allocations cross the ceiling":
            measured_late == {"meta_large": 2096, "meta_small": 96, "combined_large": 2096}
            and problems({"meta_small": measured_late["meta_small"]}, budget={}) == []
            and any("combined_large: frame 2096 B exceeds the 2048 B ceiling" in p
                    for p in problems(measured_late, budget={})),
        "mutually exclusive frames and an untyped assembly entry":
            small == {"exclusive_small": 1536, "leaf": 0}
            and problems(small, budget={}) == [],
        "missing section":
            rejected(replaced(exclusive, "<I", section_at, 0),
                     "missing .stack_sizes section"),
        "missing ordinary frame": rejected(missing, "missing .stack_sizes record for leaf"),
        "duplicate frame": rejected(duplicate, "duplicate .stack_sizes record"),
        "unknown function": rejected(unknown, "unknown function address"),
        "malformed size": rejected(malformed, "malformed .stack_sizes ULEB128"),
        "unsupported relocation": rejected(unsupported, "malformed .stack_sizes relocation"),
        "unrelocated trailing bytes": rejected(unrelocated, "unrelocated bytes"),
        "at ceiling": problems({"equal": 2048}, budget={}) == [],
        "budgeted frame within limit": problems(late, budget={"meta_large": 2096}) == [],
        "budgeted frame exceeds limit":
            any("frame 2096 B exceeds its recorded budget 2048 B" in p
                for p in problems(late, budget={"meta_large": 2048})),
        "stale budgets":
            problems(small, budget={"leaf": 3000, "gone": 4000}) == [
                "gone: budget entry for a function not in the image",
                "leaf: frame 0 B is within the ceiling; delete its budget entry",
            ],
    }
    failures = [name for name, passed in checks.items() if not passed]
    if failures:
        for name in failures:
            print(f"FAIL frame-size controls: {name}", file=sys.stderr)
        return 1
    report_pass("frame-size controls", f"{len(checks)} controls",
                controls=len(checks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
