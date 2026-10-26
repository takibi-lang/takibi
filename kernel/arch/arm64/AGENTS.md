# AArch64 kernel invariants

These instructions apply to AArch64 entry, exception, MMU, and platform code.

## EL0 exception behavior

Unhandled EL0 exceptions intentionally capture bounded allocation-free
evidence and park. Do not route around this fail-stop while diagnosing it. Use
the `debug-kernel` skill for CrashSnapshot, DDB, GDB, and SWD procedures.

## Returning to EL0

Every `eret` returning to EL0 must mask `DAIF.I` before its final writes to
`ELR_EL1`, `SPSR_EL1`, or `SP_EL0`, with nothing except further `msr`
instructions in the vulnerable interval. An interrupt there overwrites the
return context and can send EL0 into kernel text.

Use the generated exception-entry or exception-restore mechanisms when their
frame shapes fit. `el2_drop_to_el1` is a cold-boot exception because interrupt
sources are still masked and its target PSTATE masks DAIF.

`scripts/buildcheck_kernel_asm_invariants.py` disassembles the linked image and
enforces the return invariant. Do not replace that external check with a
runtime probe or additional hand-written assembly.

Exception-frame offsets are compiler-generated. Do not duplicate the packed
frame layout or maintain offsets independently. Preserve the distinction
between an IRQ entry, restoring an existing saved frame, and constructing the
synthetic state for an initial user entry; they do not share identical
interrupt-masking order.

## Assembly is a leaf

A value that crosses hand-written assembly loses its type (DECISIONS
2026-10-25). Assembly called from Takibi returns to its caller; a path that
must start in assembly saves state and enters Takibi at a declared entry
(the Makefile's `KERNEL_ASM_ENTRIES`), and Takibi decides from there. Do not
add an assembly branch that calls back into a Takibi function to finish a
decision Takibi already made: run that tail on the Takibi side, as execve's
child exec does. `scripts/buildcheck_kernel_asm_invariants.py` refuses an
undeclared entry and a declared entry nothing calls any more.
