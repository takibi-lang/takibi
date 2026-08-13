#!/usr/bin/env python3
"""
Generate AArch64 exception frame assembly constants from the Takibi struct definition.

This script parses kernel/arch/arm64/kernel/exception_frame.tkb and generates
kernel/arch/arm64/kernel/exception_context.inc with computed offsets.

The generated file ensures the assembly and compiler layouts are mechanically identical.
"""

import re
import sys
from pathlib import Path

def parse_struct_fields(tkb_path):
    """Parse ExceptionFrame struct from .tkb file and return field list."""
    with open(tkb_path, 'r') as f:
        content = f.read()

    # Find the struct packed ExceptionFrame block
    struct_match = re.search(
        r'struct\s+packed\s+ExceptionFrame\s*\{([^}]+)\}',
        content,
        re.DOTALL
    )
    if not struct_match:
        raise ValueError("Could not find 'struct packed ExceptionFrame' in " + str(tkb_path))

    struct_body = struct_match.group(1)

    # Parse field declarations: name: type
    # Types we support: usize, [u8; 16]
    fields = []

    # Process line by line to handle multiple fields per line
    for line in struct_body.split('\n'):
        # Remove comments
        line = re.sub(r'//.*', '', line).strip()
        if not line:
            continue

        # Find all "name: type;" patterns on this line
        # Match either array types [u8; 16] or word types like usize
        field_pattern = r'(\w+):\s+(\[[^\]]*\]|\w+);'

        for match in re.finditer(field_pattern, line):
            name, field_type = match.groups()
            name = name.strip()
            field_type = field_type.strip()
            fields.append((name, field_type))

    if not fields:
        raise ValueError("Could not parse any fields from ExceptionFrame struct")

    return fields

def calculate_offsets(fields):
    """Calculate byte offsets for each field, respecting alignment rules."""
    offsets = {}
    current_offset = 0

    # usize = 8 bytes, [u8; 16] = 16 bytes
    # The struct is packed but with alignment requirements for q0 (16-byte)

    for name, field_type in fields:
        # Check if this is a q-register array field
        is_q_array = '[u8;' in field_type and '16' in field_type

        # For q0-q31 fields, align to 16-byte boundary before first one
        if is_q_array:
            # q fields must be 16-byte aligned
            # Check if this is the first q field
            if name == 'q0':
                # Align current_offset to 16-byte boundary
                if current_offset % 16 != 0:
                    current_offset = ((current_offset + 15) // 16) * 16

            offsets[name] = current_offset
            current_offset += 16
        elif field_type == 'usize':
            offsets[name] = current_offset
            current_offset += 8
        else:
            raise ValueError(f"Unsupported field type: {field_type} (in field {name})")

    # Final size with 16-byte alignment
    total_size = ((current_offset + 15) // 16) * 16

    return offsets, total_size

def extract_macros(inc_path):
    """Extract existing macro definitions from the current .inc file."""
    try:
        with open(inc_path, 'r') as f:
            content = f.read()

        # Find all macros (.macro/.endm blocks), including the .endm line
        macro_pattern = r'\.macro\s+(\w+).*?\.endm'
        macros = {}
        for match in re.finditer(macro_pattern, content, re.DOTALL):
            macro_name = match.group(1)
            macro_body = content[match.start():match.end()]
            macros[macro_name] = macro_body

        return macros
    except FileNotFoundError:
        return {}

def generate_inc_file(fields, offsets, total_size, inc_path):
    """Generate the assembly .inc file content."""
    lines = [
        "/* The one exception-frame shape. Every EL1 exception entry that returns to",
        " * the interrupted context uses this layout: EL0 sync (syscalls), Lower-EL",
        " * IRQ, and Current-EL-SPx IRQ. A saved SP_EL1 points at offset zero, and the",
        " * frame contains every architectural value the scheduler must preserve before",
        " * selecting a different context -- x0-x30, SP_EL0, ELR_EL1, SPSR_EL1,",
        " * TPIDR_EL0, and the FP/SIMD state q0-q31 + FPSR + FPCR.",
        " *",
        " * The FP/SIMD half is not optional for any entry, including the Current-EL",
        " * one: kernel/arch/arm64/boot/entry.S enables FP/SIMD in CPACR_EL1 for",
        " * ordinary compiled code, LLVM does select q registers in kernel .tkb code,",
        " * and since issue #187 syscall handling runs with IRQs unmasked -- so EL1",
        " * kernel code holding live q registers can be interrupted. GitHub issue #223",
        " * removed the separate 272-byte general-registers-only Current-EL frame that",
        " * used to exist alongside this one; a second layout is exactly what let that",
        " * asymmetry go unnoticed, so there is deliberately only one now.",
        " */",
        f"    .equ EXC_CONTEXT_SIZE,          0x{total_size:x}",
    ]

    # Add offset constants in order of appearance
    for name, field_type in fields:
        offset = offsets[name]
        const_name = f"EXC_CONTEXT_{name.upper()}"
        lines.append(f"    .equ {const_name},          0x{offset:03x}")

    # Add empty line before macros
    lines.append("")

    # Extract existing macros from current file to preserve hand-written logic
    macros = extract_macros(inc_path)
    if macros:
        for macro_name in sorted(macros.keys()):
            lines.append(macros[macro_name])
            if macro_name != list(macros.keys())[-1]:
                lines.append("")
    else:
        # Fallback: add placeholder if no macros found
        lines.append(".macro EXC_CONTEXT_SAVE")
        lines.append("    /* TODO: implement exception save sequence */")
        lines.append(".endm")
        lines.append("")
        lines.append(".macro EXC_CONTEXT_RESTORE")
        lines.append("    /* TODO: implement exception restore sequence */")
        lines.append(".endm")

    return '\n'.join(lines)

def main():
    # Find paths relative to repo root
    repo_root = Path(__file__).parent.parent
    tkb_path = repo_root / "kernel" / "arch" / "arm64" / "kernel" / "exception_frame.tkb"
    inc_path = repo_root / "kernel" / "arch" / "arm64" / "kernel" / "exception_context.inc"

    if not tkb_path.exists():
        print(f"Error: {tkb_path} not found", file=sys.stderr)
        sys.exit(1)

    try:
        # Parse struct
        fields = parse_struct_fields(tkb_path)

        # Calculate offsets
        offsets, total_size = calculate_offsets(fields)

        # Extract macros BEFORE generating (read current file if it exists)
        # This preserves the hand-written macro logic
        old_macros = extract_macros(inc_path) if inc_path.exists() else {}

        # Generate assembly content (preserving existing macros)
        inc_content = generate_inc_file(fields, offsets, total_size, inc_path)

        # Check if file exists and has same content (skip write if unchanged)
        if inc_path.exists():
            existing_content = inc_path.read_text()
            if existing_content == inc_content + '\n':
                # File is already up-to-date; silently succeed
                sys.exit(0)

        # Write output
        inc_path.write_text(inc_content + '\n')

        # Print status only on actual changes (not every build)
        print(f"Generated {inc_path}")

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
