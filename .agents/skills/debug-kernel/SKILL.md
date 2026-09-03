---
name: debug-kernel
description: Diagnose Takibi kernel hangs, crashes, boot failures, exceptions, intermittent or timing-sensitive failures, QEMU failures, and RPi5 hardware failures. Use before investigating a failing kernel test, stuck UART, retained crash, scheduler or interrupt failure, or suspected hardware-only bug. Do not use for compiler-only type errors or ordinary host-native linux_user failures.
---

# Debug the Takibi kernel

Use the cheapest evidence that preserves the failure mechanism. Do not edit the
kernel merely to make it narrate a timing-sensitive failure before checking the
existing bounded diagnostics.

## Route the investigation

1. If UART is responsive, read [references/ddb.md](references/ddb.md) and use
   DDB before adding prints to scheduler, exception, IRQ, VM, or process paths.
2. For a parked exception, corrupted-looking retained evidence, SWD/OpenOCD, or
   postmortem work, read [references/crash-evidence.md](references/crash-evidence.md).
3. For intermittent failures, perturbation-sensitive failures, bisection, or a
   test that fails once and passes on rerun, read
   [references/investigation.md](references/investigation.md). Read its
   "Failures that are not the change under test" section FIRST when a QEMU
   lane fails: two known failures there look like defects in whatever is being
   worked on and are not.
4. For DWARF, QEMU gdbstub, or source-line investigation, read
   [references/dwarf.md](references/dwarf.md). For PC-sampling performance work,
   use the separate `profile-qemu` skill.

## Always preserve these distinctions

- QEMU TCG does not model physically separate caches. A QEMU pass cannot prove
  cache maintenance, memory ordering, real interrupt timing, or hardware
  concurrency correct; use the RPi5 lane when the verdict depends on them.
- An I/O-bound or interrupt-driven workload appearing almost entirely idle in a
  PC-sampling profile is a resolution mismatch, not evidence that no work is
  happening.
- A rerun that passes does not prove an intermittent defect fixed. Measure the
  observed rate, run a discriminating experiment, and verify the mechanism.
- Capture timing-sensitive evidence in bounded globals or existing diagnostic
  rings before printing. UART output can suppress the failure being observed.
- Diagnose unless the user also asked for a fix. Do not broaden a diagnostic
  request into an implementation change.

Use `kernel/README.md` as the authoritative public description of DDB commands
and current kernel behavior. Treat this skill as operational guidance, not a
replacement for that maintained documentation.
