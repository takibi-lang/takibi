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

`scripts/check_kernel_asm_invariants.py` disassembles the linked image and
enforces the return invariant. Do not replace that external check with a
runtime probe or additional hand-written assembly.

Exception-frame offsets are compiler-generated. Do not duplicate the packed
frame layout or maintain offsets independently. Preserve the distinction
between an IRQ entry, restoring an existing saved frame, and constructing the
synthetic state for an initial user entry; they do not share identical
interrupt-masking order.
