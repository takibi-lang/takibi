#!/usr/bin/env python3
"""Controls for check_kernel_compile_flags.py (GitHub issue #781): a kernel
compile that bypasses KERNEL_COMPILE_FLAGS, one that respells a shared flag
beside it, a flags variable that respells one, and a kernel-compiling script
that spells its own flags are each refused; the EL0 define and a prerequisite
line are not invocations; the real Makefile and scripts are accepted."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_kernel_compile_flags as check  # noqa: E402
from pass_line import report_pass  # noqa: E402

BYPASS = ("\nplanted.o: kernel/kernel/main.tkb\n"
          "\t$(TAKIBI) $(KERNEL_QEMU_MAIN_TKB) --target $(QEMU_TARGET) "
          "--cpu $(QEMU_CPU) --forbid-trap -o $@\n")
RESPELL = ("\nplanted.o: kernel/kernel/main.tkb\n"
           "\t$(TAKIBI) $(KERNEL_QEMU_MAIN_TKB) $(KERNEL_QEMU_COMPILE_FLAGS) "
           "--device-semantics-file kernel/x.tkb -o $@\n")
PATH_BYPASS = ("\nplanted.o:\n\tcd _build/x && $(abspath $(TAKIBI)) "
               "kernel/platform/qemu/init.tkb -o $(abspath $@)\n")
FLAGS_VAR = "\nKERNEL_PLANTED_FLAGS := $(KERNEL_QEMU_COMPILE_FLAGS) --regions\n"
EL0 = ("\ndefine KERNEL_PLANTED_EL0\n\t$(TAKIBI) $< --target $(RPI5_TARGET) -o $@\nendef\n")
PREREQ = "\nplanted.o: $(KERNEL_QEMU_MAIN_TKB) $(TAKIBI)\n"


def main():
    makefile = (check.ROOT / "Makefile").read_text(encoding="ascii")
    names = check.kernel_scripts(makefile)
    scripts = {n: (check.ROOT / n).read_text(encoding="ascii") for n in names}
    one = names[0] if names else None
    spelled = {**scripts, one: scripts[one].replace(
        "*kernel_compile_flags(),", '"--regions", "--forbid-trap",')} if one else scripts
    exempt_el0 = makefile + EL0.replace("KERNEL_PLANTED_EL0", "KERNEL_EL0_COMPILE")
    cases = {
        "a kernel compile without the shared flags is refused": (True, makefile + BYPASS, scripts),
        "a respelled shared flag beside them is refused": (True, makefile + RESPELL, scripts),
        "a kernel/*.tkb path compile without them is refused": (True, makefile + PATH_BYPASS, scripts),
        "a flags variable respelling a shared flag is refused": (True, makefile + FLAGS_VAR, scripts),
        "an unlisted define compiling for a kernel target is refused": (True, makefile + EL0, scripts),
        "a script spelling its own flags is refused": (True, makefile, spelled),
        "the EL0 define is exempt": (False, exempt_el0, scripts),
        "a prerequisite line is not an invocation": (False, makefile + PREREQ, scripts),
        "the real Makefile and scripts are accepted": (False, makefile, scripts),
    }
    failures = []
    for label, (refuse, mk, sc) in cases.items():
        problems, _ = check.problems_in(mk, sc)
        if bool(problems) != refuse:
            failures.append(f"{label}: got {problems}")
    if len(names) < 3:
        failures.append(f"only {len(names)} kernel-compiling scripts found; "
                        "the script controls examined too little")
    for failure in failures:
        print(f"ERROR\tkernel-compile-flags-controls: {failure}")
    if failures:
        print("FAIL kernel-compile-flags-controls")
        return 1
    report_pass("kernel-compile-flags-controls",
                "bypass, respelling, flags-variable, unlisted define and "
                "script cases refused; EL0 define, prerequisites and the real "
                "tree accepted", cases=len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
