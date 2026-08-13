#!/usr/bin/env python3
"""
Verify that the AArch64 exception-frame offsets and hand-written macros are
present and consistent (GitHub issue #286).

Checks:
1. exception_context_offsets.inc (generated) has the expected .equ constants
2. exception_context.inc (hand-written) `.include`s the generated file
3. exception_context.inc's EXC_CONTEXT_SAVE/EXC_CONTEXT_RESTORE macros
   contain real save/restore instructions, not placeholder/missing bodies --
   this is the check that would have caught issue #286's own regression,
   where a deleted generated file silently produced empty macros and the
   kernel faulted the instant it returned to EL0 with a garbage frame.
4. Every `[sp, #...]` offset in those macros is a symbolic EXC_CONTEXT_*
   reference, never a bare hex literal -- a raw literal does not move if
   the struct's field order changes, so it would silently keep addressing
   the OLD slot after a regeneration that updated every other consumer.
   This is the second, subtler gap found in the same 2026-08-13 post-mortem:
   the macros were hand-written with hex literals for most of x0-x29 and
   q0-q31 even after offsets became generated, so a field reorder would
   have desynced them with nothing to catch it. Routing every offset
   through its symbol makes the assembler the enforcement mechanism.
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
    errors = []
    equ_consts = parse_equ_constants(offsets_inc_path)

    expected_offsets = {
        'EXC_CONTEXT_SIZE': 0x330,
        'EXC_CONTEXT_X0': 0x000,
        'EXC_CONTEXT_X30': 0x0f0,
        'EXC_CONTEXT_SP_EL0': 0x0f8,
        'EXC_CONTEXT_ELR_EL1': 0x100,
        'EXC_CONTEXT_SPSR_EL1': 0x108,
        'EXC_CONTEXT_Q0': 0x110,
        'EXC_CONTEXT_Q31': 0x300,
        'EXC_CONTEXT_FPSR': 0x310,
        'EXC_CONTEXT_FPCR': 0x318,
        'EXC_CONTEXT_TPIDR_EL0': 0x320,
    }

    for name, expected in expected_offsets.items():
        if name not in equ_consts:
            errors.append(f"Missing offset definition: {name}")
        elif equ_consts[name] != expected:
            errors.append(f"{name} is 0x{equ_consts[name]:03x}, expected 0x{expected:03x}")

    return errors

def verify_macros(exc_frame_inc):
    """Check the hand-written macros actually contain real instructions."""
    errors = []
    content = exc_frame_inc.read_text()

    if '.include' not in content or 'exception_context_offsets.inc' not in content:
        errors.append(
            "exception_context.inc does not .include exception_context_offsets.inc"
        )

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

        if 'tpidr_el0' not in body:
            errors.append(
                f"{macro_name} does not reference tpidr_el0 (GitHub issue #227's "
                f"original omission -- must never regress)"
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

    errors = verify_offsets(offsets_inc) + verify_macros(exc_frame_inc)

    if errors:
        print("Exception-frame consistency check FAILED:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)

if __name__ == "__main__":
    main()
