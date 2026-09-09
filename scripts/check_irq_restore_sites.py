#!/usr/bin/env python3
"""An `enable_irq()` that consults nothing about the state it is changing.

`enable_irq()` is ABSOLUTE. It unmasks DAIF.I whatever the caller was doing,
so a function that calls it without owning the prior interrupt state unmasks
interrupts underneath whoever masked them. `kernel/lib/pool_lock.tkb` carries
the answer -- `mutex_irq_save()` returns the state and `mutex_irq_restore()`
puts back exactly that -- and this refuses the shape that skips it.

WHY THIS EXISTS. GitHub issue #454's console queue called `enable_irq()`
unconditionally in `uart_putc`, and `kernel_boot_log` is reached from paths
that already hold IRQs masked. DDB is one of them: `crash_console_run()` masks
with a bare `disable_irq()` and then blocks on input. The result was that the
debugger never came up on RPi5 -- `first-prompt=never` -- while QEMU passed,
so it cost four instrumented board runs to bisect. The failure presents as
"the debugger is gone", which is the worst possible presentation, because the
debugger is what one would use to investigate it.

WHAT IT IS NOT. This is lexical. It does not follow the call graph, so it
cannot see a helper that restores IRQs while a caller's guard is live -- that
is GitHub issue #528, and it needs the compiler's effect and liveness
machinery rather than a grep. What this catches is the direct, common shape,
at `langcheck` cost, today. The two are complementary and #528 stays open.

THE RULE. A call is accepted when the same line consults saved state: either
a condition naming a mask variable (`if (irq_was_masked == 0) {
enable_irq(); }`, which is `mutex_irq_restore` written by hand and appears 17
times in this tree) or the definition of `mutex_irq_restore` itself. Anything
else must be declared below with the reason it is allowed to be absolute.
Seven sites are, and all seven are places where nothing could have been
masked yet. Declaring is not a workaround -- it is the check asking for the
sentence a reviewer would otherwise have to reconstruct.

A guarded site is not PROVEN correct by this check; it is proven to consult
something. Turning the seventeen into real `mutex_irq_restore` calls is
issue #528's first step and lives in Territory A's files.
"""

import pathlib
import re
import sys

from pass_line import report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
KERNEL = REPO / "kernel"

CALL = re.compile(r"\benable_irq\s*\(\s*\)")
DEFINITION = re.compile(r"\bfn\s+enable_irq\s*\(")
# The saved state, consulted on the same line as the call. `mask` covers
# `irq_was_masked` and `before_irq_masked`; `flags` covers the saved word
# mutex_irq_save returns.
GUARDED = re.compile(
    r"\bif\s*\(\s*\b[A-Za-z0-9_]*(?:mask|flags)[A-Za-z0-9_]*\b\s*=="
    r"[^)]*\)\s*\{[^}]*\benable_irq\s*\(\s*\)")

# path -> line text -> why this site may be absolute. The line text is the
# anchor rather than a number so the declaration survives an edit above it and
# dies when the site itself changes.
ALLOWED = {
    "kernel/arch/arm64/kernel/secondary.tkb": {
        "enable_irq();":
            "the secondary core's own bring-up and its idle loop. Nothing on "
            "this core has masked anything yet -- it arrived from PSCI "
            "CPU_ON with a fresh DAIF",
    },
    "kernel/platform/qemu/intc.tkb": {
        "enable_irq();":
            "platform_irq_init(), which is where interrupt delivery is turned "
            "on for the first time in the boot",
    },
    "kernel/platform/rpi5/intc.tkb": {
        "enable_irq();":
            "platform_irq_init(), same as QEMU's",
    },
    "kernel/kernel/syscall.tkb": {
        "enable_irq();":
            "a syscall entered from EL0, which cannot have been entered with "
            "IRQs masked, closing a mask this same function opened a few "
            "lines above. Issue #528's first step would make these "
            "mutex_irq_restore calls and this declaration would go",
    },
}


def significant_lines(path: pathlib.Path):
    for number, raw in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        yield number, raw, raw.split("//")[0]


def main() -> int:
    problems = []
    checked = 0
    guarded = 0
    used = set()
    declared_sites = 0
    for path in sorted(KERNEL.rglob("*.tkb")):
        relative = path.relative_to(REPO).as_posix()
        for number, raw, code in significant_lines(path):
            if not CALL.search(code) or DEFINITION.search(code):
                continue
            checked += 1
            if GUARDED.search(code):
                guarded += 1
                continue
            stripped = raw.strip()
            reason = ALLOWED.get(relative, {}).get(stripped)
            if reason:
                used.add((relative, stripped))
                declared_sites = declared_sites + 1
                continue
            problems.append(
                f"{relative}:{number}: `enable_irq()` with nothing on this "
                f"line consulting the state it overwrites. It unmasks "
                f"whatever the caller was doing -- which is how issue #454's "
                f"console removed DDB from RPi5. Use mutex_irq_save()/"
                f"mutex_irq_restore(flags) from kernel/lib/pool_lock.tkb, or "
                f"declare the site in {pathlib.Path(__file__).name} with the "
                f"reason nothing could be masked here")

    # A declaration that outlives its site reads as current and is worse than
    # no declaration at all -- the same rule check_platform_file_parity.py
    # applies to its own list.
    for relative, sites in ALLOWED.items():
        for text in sites:
            if (relative, text) not in used:
                problems.append(
                    f"{relative}: declares `{text}` as an allowed absolute "
                    f"unmask, and no such line is there any more. Remove the "
                    f"declaration; every entry left in the list has to be one "
                    f"a reviewer can still go and read")

    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"FAIL irq-restore-sites: {len(problems)} site(s) restore "
              "interrupts without owning the state they overwrite",
              file=sys.stderr)
        return 1
    report_pass("irq-restore-sites",
                f"{checked} enable_irq() call sites: {guarded} consult saved "
                f"state on the line that restores it, {declared_sites} are "
                f"declared absolute by {len(used)} entries because nothing "
                "could be masked there, and none unmasks underneath a caller",
                counts=checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
