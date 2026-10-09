# Signal and anonymous-memory boundary negative controls

The standalone EL0 fixture passed the ordinary QEMU boot's 71 views and the
shell halt, poweroff and restart checks on 2026-10-09. Isolated kernel source
overlays then planted each regression below; production syscall code was not
edited. Each overlay built with --forbid-trap, and the maintained QEMU runner
exited 1. Both the exit status and the listed UART witness were required.

| Planted regression | Fixture witness |
| --- | --- |
| Remove FPSIMD magic comparison | First normal signal case passes, then FAIL signal child status |
| Remove FPSIMD size comparison | Magic refusal passes, then FAIL signal child status |
| Remove PC alignment comparison | After size refusal, fail-stop with EC 0x22 and odd ELR 0x80010b89 |
| Restore user PSTATE without the NZCV mask | After PC refusal, instruction-fetch fail-stop with saved SPSR 0xf00003c5 |
| Ignore signal-frame write failure | After PSTATE case, data-abort fail-stop with FAR zero |
| Write zero instead of si_signo | FAIL signal child status in the first signal case |
| Write zero instead of the pre-suspend mask | FAIL signal child status in the first signal case |
| Restore zero instead of each saved vector word | FAIL signal child status in the first signal case |
| Skip anonymous-map zero fill for the fixture | FAIL reused mmap not zero |
| Ignore brk's live-map collision verdict | FAIL brk crossed mapping |

The memory zero-fill control is scoped to the fixture's boundary_memory
return-PC range, 0x80010620 through 0x800107f3. The actual ELF symbol is at
linked 0x10620 with size 0x1d4; process_image's static-PIE loader adds
USER_TEXT_VA, 0x80000000. The fixture ELF SHA256 is
`da08bf2b0fc64bf70e9ba76ce19ddd7a9f85a6055f0bcbd7a13dca7a3f89e7a0`.
The overlay reconstructs MaybeFrame after reading the PC, preserving its
existing affine ownership. This scope keeps unrelated startup mappings
working so the tested mmap operation reaches its consumer.

An earlier global removal of zero fill failed before the new fixture ran;
that run is not counted as evidence for this fixture. Neither the scoped
control nor its PC selector is shipped in production. The syscall checks are
unchanged. Raw input remains subject to runtime validation; these controls
verify the refusal and sanitization paths rather than proving the ABI for all
possible frames or mappings.

The full UART captures, selected EL0 ELF, control kernel ELFs, overlay syscall
sources and status witnesses were retained locally under
`.git/takibi-diagnostics/642/2026-10-09/` before the clean publication gate.
