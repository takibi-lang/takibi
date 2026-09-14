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

WHAT IT IS NOT. This is lexical. It does not follow the call graph, so the
compiler's effect and liveness rule separately rejects a helper that restores
IRQs while a caller's IRQ-owning guard is live. What this catches is the
direct, common shape at `langcheck` cost. The two checks are complementary.

THE RULE. A call is accepted when the same line consults saved state. The
conditional inside `mutex_irq_restore` is the kernel's one such site. Anything
else must be declared below with the reason it is allowed to be absolute.
Every declared site is a place where nothing could have been masked yet. The
terminal read in syscall.tkb used to be one more: it masked, looked at the
ring, and unmasked absolutely. It now holds the process-run lock instead, whose
release restores what it saved (GitHub issue #547). Declaring is
not a workaround -- it is the check asking for the sentence a reviewer would
otherwise have to reconstruct.
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
# `mutex_irq_save` returns. Ordinary restores call `mutex_irq_restore`, so its
# definition is the sole guarded `enable_irq` site.
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
