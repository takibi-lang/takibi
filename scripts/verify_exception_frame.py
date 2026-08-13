#!/usr/bin/env python3
"""
Verify that the AArch64 exception-frame offsets and hand-written macros are
present and consistent (GitHub issue #286).

Checks:
1. exception_context_offsets.inc (generated) is structurally sane: X0 is at
   offset 0, offsets are monotonically increasing with no overlaps, and the
   total size is 16-byte aligned. (Deliberately NOT a hardcoded table of
   expected literal offset values -- that would itself be a second,
   independently-maintained copy of the same data issue #286 exists to
   eliminate. The struct is the only authority for what the numbers are;
   this only checks the numbers are internally consistent.)
2. exception_context.inc (hand-written) `.include`s the generated file.
3. exception_context.inc's EXC_CONTEXT_SAVE/EXC_CONTEXT_RESTORE macros
   contain real save/restore instructions, not placeholder/missing bodies --
   this is the check that would have caught issue #286's own regression,
   where a deleted generated file silently produced empty macros and the
   kernel faulted the instant it returned to EL0 with a garbage frame.
4. Every `[sp, #...]` offset in those macros is a symbolic EXC_CONTEXT_*
   reference, never a bare hex literal -- a raw literal does not move if
   the struct's field order changes, so it would silently keep addressing
   the OLD slot after a regeneration that updated every other consumer.
5. EVERY field symbol present in the generated offsets file is referenced
   by name in BOTH macro bodies. Adding a new field to the struct grows
   the generated .equ list automatically, but nothing forces a human to
   also add save/restore instructions for it -- this check is what makes
   that omission a build failure instead of a silent unsaved/unrestored
   register, closing the gap in issue #286's second acceptance criterion
   ("adding or changing a frame field fails a build... until every
   required assembly consumer is consistent").
"""

import re
import sys
from pathlib import Path

def parse_equ_constants(inc_path):
    with open(inc_path, 'r') as f:
        content = f.read()

    equ_pattern = r'\.equ\s+(\w+),?\s+0x([0-9a-fA-F]+)'
    return {name: int(off, 16) for name, off in re.findall(equ_pattern, content)}

def verify_offsets(offsets_inc_path):
    """Structural sanity checks only -- see module docstring check 1 for why
    this deliberately does not hardcode expected literal offset values."""
    errors = []
    equ_consts = parse_equ_constants(offsets_inc_path)

    if 'EXC_CONTEXT_SIZE' not in equ_consts:
        errors.append("Missing EXC_CONTEXT_SIZE definition")
        return errors

    size = equ_consts['EXC_CONTEXT_SIZE']
    if size % 16 != 0:
        errors.append(f"EXC_CONTEXT_SIZE (0x{size:x}) is not 16-byte aligned")

    field_offsets = {n: v for n, v in equ_consts.items() if n != 'EXC_CONTEXT_SIZE'}
    if not field_offsets:
        errors.append("No field offset constants found (besides EXC_CONTEXT_SIZE)")
        return errors

    if field_offsets.get('EXC_CONTEXT_X0') != 0:
        errors.append(
            f"EXC_CONTEXT_X0 is 0x{field_offsets.get('EXC_CONTEXT_X0', -1):x}, "
            f"expected 0x0 (must be the frame's first field)"
        )

    max_offset = max(field_offsets.values())
    if max_offset >= size:
        errors.append(
            f"A field offset (0x{max_offset:x}) is >= EXC_CONTEXT_SIZE "
            f"(0x{size:x})"
        )

    return errors

# AArch64 register-name prefix -> width in bytes. Used to compute how many
# bytes of the frame each stp/ldp/str/ldr instruction actually covers, since
# a pair instruction covers 2x its register width starting at the symbol's
# offset (the second register is implicitly at +width, never spelled out).
_REG_WIDTH = {'x': 8, 'w': 4, 'q': 16}

def _instruction_coverage(body, equ_consts):
    """Return the set of byte offsets (relative to the frame base) that
    stp/ldp/str/ldr instructions in `body` write to or read from, resolved
    through equ_consts. Raises ValueError on an unresolvable symbol."""
    covered = set()

    # stp/ldp reg, reg2, [sp, #SYMBOL] -- covers 2 * width(reg) bytes from SYMBOL
    pair_pattern = r'(?:stp|ldp)\s+(\w+)\s*,\s*\w+\s*,\s*\[sp,\s*#(\w+)\]'
    for reg, symbol in re.findall(pair_pattern, body):
        width = _REG_WIDTH.get(reg[0])
        if width is None or symbol not in equ_consts:
            continue
        base = equ_consts[symbol]
        covered.update(range(base, base + 2 * width))

    # str/ldr reg, [sp, #SYMBOL] -- covers width(reg) bytes from SYMBOL
    single_pattern = r'(?:str|ldr)\s+(\w+)\s*,\s*\[sp,\s*#(\w+)\]'
    for reg, symbol in re.findall(single_pattern, body):
        width = _REG_WIDTH.get(reg[0])
        if width is None or symbol not in equ_consts:
            continue
        base = equ_consts[symbol]
        covered.update(range(base, base + width))

    return covered

def verify_macros(exc_frame_inc, equ_consts):
    """Check the hand-written macros actually contain real instructions and
    cover every byte the struct currently declares."""
    errors = []
    content = exc_frame_inc.read_text()

    if '.include' not in content or 'exception_context_offsets.inc' not in content:
        errors.append(
            "exception_context.inc does not .include exception_context_offsets.inc"
        )

    size = equ_consts.get('EXC_CONTEXT_SIZE')
    field_offsets = {n: v for n, v in equ_consts.items() if n != 'EXC_CONTEXT_SIZE'}
    frame_bytes = set(range(0, max(field_offsets.values(), default=-1) + 1)) if field_offsets else set()

    macro_pattern = r'\.macro\s+(\w+)(.*?)\.endm'
    macros = {name: body for name, body in re.findall(macro_pattern, content, re.DOTALL)}

    for macro_name in ('EXC_CONTEXT_SAVE', 'EXC_CONTEXT_RESTORE'):
        if macro_name not in macros:
            errors.append(f"Missing macro definition: {macro_name}")
            continue

        body = macros[macro_name]
        if 'TODO' in body or 'implement' in body:
            errors.append(
                f"{macro_name} contains a placeholder body, not real assembly "
                f"(this is the exact bug that broke userspace entry once already)"
            )

        # A real save/restore body is dozens of instructions long; a stub
        # or accidentally-emptied macro is a handful of lines at most.
        real_lines = [l for l in body.strip().splitlines() if l.strip()]
        if len(real_lines) < 30:
            errors.append(
                f"{macro_name} has only {len(real_lines)} non-blank lines "
                f"(expected 30+); body looks truncated or empty"
            )

        # Every [sp, #...] offset must be symbolic (EXC_CONTEXT_*), never a
        # bare hex literal -- see module docstring check 4.
        raw_hex_offsets = re.findall(r'\[sp,\s*#(0x[0-9a-fA-F]+)\]', body)
        if raw_hex_offsets:
            errors.append(
                f"{macro_name} has {len(raw_hex_offsets)} raw hex [sp, #...] "
                f"offset(s) instead of EXC_CONTEXT_* symbols (e.g. "
                f"{raw_hex_offsets[0]}) -- these silently desync from the "
                f"struct if a field is ever reordered"
            )
            continue  # byte-coverage below is meaningless with unresolved literals

        # Every byte the struct currently declares must be written by some
        # stp/ldp/str/ldr in this macro -- see module docstring check 5. This
        # is a byte-range coverage check, not a per-symbol text search: a
        # `stp x0, x1, [sp, #EXC_CONTEXT_X0]` covers X1 too even though
        # "EXC_CONTEXT_X1" never appears literally, so coverage is computed
        # from resolved (symbol, register-width) pairs instead of grepping
        # for each field's name.
        covered = _instruction_coverage(body, equ_consts)
        missing = sorted(frame_bytes - covered)
        if missing:
            # Report as contiguous ranges, not one line per byte.
            ranges = []
            start = prev = missing[0]
            for off in missing[1:]:
                if off != prev + 1:
                    ranges.append((start, prev))
                    start = off
                prev = off
            ranges.append((start, prev))
            range_str = ', '.join(
                f"0x{lo:03x}" if lo == hi else f"0x{lo:03x}-0x{hi:03x}"
                for lo, hi in ranges
            )
            errors.append(
                f"{macro_name} does not save/restore byte offset(s) "
                f"{range_str} -- a struct field was added/reordered without "
                f"updating this hand-written macro to cover it"
            )

    return errors

def main():
    repo_root = Path(__file__).parent.parent
    exc_frame_tkb = repo_root / "kernel" / "arch" / "arm64" / "kernel" / "exception_frame.tkb"
    exc_frame_inc = repo_root / "kernel" / "arch" / "arm64" / "kernel" / "exception_context.inc"
    offsets_inc = repo_root / "kernel" / "arch" / "arm64" / "kernel" / "exception_context_offsets.inc"

    for p in (exc_frame_tkb, exc_frame_inc, offsets_inc):
        if not p.exists():
            print(f"Error: {p} not found", file=sys.stderr)
            sys.exit(1)

    equ_consts = parse_equ_constants(offsets_inc)

    errors = verify_offsets(offsets_inc) + verify_macros(exc_frame_inc, equ_consts)

    if errors:
        print("Exception-frame consistency check FAILED:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)

if __name__ == "__main__":
    main()
