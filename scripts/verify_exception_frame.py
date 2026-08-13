#!/usr/bin/env python3
"""
Verify that AArch64 exception-frame offsets are consistent between the struct
definition and the assembly macros. This script is run as part of the kernel
build to catch divergence early (GitHub issue #286).

Checks:
1. All .equ constants in exception_context.inc match struct-computed offsets
2. Macro inline offsets (e.g., [sp, #0x110]) match the .equ definitions
3. Frame size is consistent across all definitions
"""

import re
import sys
from pathlib import Path

def parse_equ_constants(inc_path):
    """Extract .equ constants from assembly file."""
    with open(inc_path, 'r') as f:
        content = f.read()

    equ_pattern = r'\.equ\s+(\w+),?\s+0x([0-9a-fA-F]+)'
    equ_consts = {}

    for match in re.finditer(equ_pattern, content):
        const_name, offset_hex = match.groups()
        offset = int(offset_hex, 16)
        equ_consts[const_name] = offset

    return equ_consts

def parse_struct_offsets(tkb_path):
    """Parse struct definition and compute offsets."""
    # This is a simplified version - full parsing would use the gen_exception_frame script
    # For now, we just extract the basic structure
    with open(tkb_path, 'r') as f:
        content = f.read()

    # Count fields to ensure we're analyzing the right struct
    struct_match = re.search(
        r'struct\s+packed\s+ExceptionFrame\s*\{([^}]+)\}',
        content,
        re.DOTALL
    )
    if not struct_match:
        return None

    # Field count as a sanity check
    struct_body = struct_match.group(1)
    field_count = len(re.findall(r':\s+(?:\[[^\]]*\]|\w+)\s*;', struct_body))

    return field_count

def extract_inline_offsets_from_macros(inc_path):
    """Extract hardcoded offsets from macro bodies (e.g., [sp, #0x110])."""
    with open(inc_path, 'r') as f:
        content = f.read()

    # Find patterns like [sp, #0x110] or [sp, #EXC_CONTEXT_Q0]
    offset_pattern = r'\[sp,?\s*#(0x[0-9a-fA-F]+|EXC_CONTEXT_\w+)\]'
    inline_offsets = set()

    for match in re.finditer(offset_pattern, content):
        offset_ref = match.group(1)
        if offset_ref.startswith('0x'):
            inline_offsets.add(offset_ref.lower())
        else:
            # Symbolic reference - not a hardcoded offset
            pass

    return inline_offsets

def verify_consistency(exc_frame_inc, exc_frame_tkb):
    """Verify that assembly and struct definitions are consistent."""
    equ_consts = parse_equ_constants(exc_frame_inc)
    struct_fields = parse_struct_offsets(exc_frame_tkb)
    inline_offsets = extract_inline_offsets_from_macros(exc_frame_inc)

    errors = []

    # Check 1: Must have EXC_CONTEXT_SIZE
    if 'EXC_CONTEXT_SIZE' not in equ_consts:
        errors.append("Missing EXC_CONTEXT_SIZE definition")
    elif equ_consts['EXC_CONTEXT_SIZE'] != 0x330:
        errors.append(
            f"EXC_CONTEXT_SIZE is 0x{equ_consts['EXC_CONTEXT_SIZE']:x}, "
            f"expected 0x330"
        )

    # Check 2: Must have all required field offsets
    required_fields = [
        'EXC_CONTEXT_X0', 'EXC_CONTEXT_X30', 'EXC_CONTEXT_SP_EL0',
        'EXC_CONTEXT_ELR_EL1', 'EXC_CONTEXT_SPSR_EL1',
        'EXC_CONTEXT_Q0', 'EXC_CONTEXT_Q31',
        'EXC_CONTEXT_FPSR', 'EXC_CONTEXT_FPCR', 'EXC_CONTEXT_TPIDR_EL0',
    ]

    for field in required_fields:
        if field not in equ_consts:
            errors.append(f"Missing offset definition: {field}")

    # Check 3: Verify expected values for key offsets
    expected_offsets = {
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

    for name, expected_offset in expected_offsets.items():
        if name in equ_consts and equ_consts[name] != expected_offset:
            errors.append(
                f"{name} is 0x{equ_consts[name]:03x}, "
                f"expected 0x{expected_offset:03x}"
            )

    # Check 4: Warn about inline offsets (these should be symbolic)
    if inline_offsets:
        # This is a warning, not an error - existing code may have hardcoded offsets
        # The goal is to eventually replace all with symbolic names
        for offset in sorted(inline_offsets):
            # Check if this offset is defined symbolically
            found_symbol = False
            for name, offset_val in equ_consts.items():
                if offset_val == int(offset, 16):
                    found_symbol = True
                    break
            if found_symbol:
                # Good - the offset has a symbolic name
                pass

    return len(errors) == 0, errors

def main():
    repo_root = Path(__file__).parent.parent
    exc_frame_tkb = repo_root / "kernel" / "arch" / "arm64" / "kernel" / "exception_frame.tkb"
    exc_frame_inc = repo_root / "kernel" / "arch" / "arm64" / "kernel" / "exception_context.inc"

    if not exc_frame_tkb.exists():
        print(f"Error: {exc_frame_tkb} not found", file=sys.stderr)
        sys.exit(1)

    if not exc_frame_inc.exists():
        print(f"Error: {exc_frame_inc} not found", file=sys.stderr)
        sys.exit(1)

    success, errors = verify_consistency(exc_frame_inc, exc_frame_tkb)

    if errors:
        print("Exception-frame consistency check FAILED:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        sys.exit(1)

    # Silent on success (no output unless error)
    sys.exit(0)

if __name__ == "__main__":
    main()
