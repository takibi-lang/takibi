#!/usr/bin/env python3
"""Every kernel compile takes the Makefile's one flag set (GitHub issue #781).

Adding --device-semantics-file (#720) meant touching every kernel compile
invocation by hand, and #760's DUNE_ROOT showed the same scattering. The
flags now live once, in KERNEL_COMPILE_FLAGS and its per-platform
KERNEL_QEMU_COMPILE_FLAGS / KERNEL_RPI5_COMPILE_FLAGS. This check refuses:

- a Makefile `$(TAKIBI)` invocation that compiles kernel sources (it names a
  kernel target, a $(KERNEL_*_TKB)/$(KERNEL_*_SRCS) source set or a
  kernel/*.tkb path) but reaches neither per-platform variable, directly or
  through a KERNEL_*_FLAGS variable defined from one;
- such an invocation that spells one of the shared flags itself, which is
  how a second, drifting copy starts;
- a script the Makefile runs with $(KERNELBUILD_CHECK_ARGS) (it compiles
  kernel sources) that does not take its flags from
  scripts/kernel_compile_flags.py, or spells a shared flag or the target.

EXEMPT_DEFINES names the one invocation that compiles for a kernel target
but is not a kernel compile, and why.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pass_line import report_pass  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
PLATFORM_VARS = ("$(KERNEL_QEMU_COMPILE_FLAGS)", "$(KERNEL_RPI5_COMPILE_FLAGS)")
SHARED_FLAGS = ("--target", "--cpu", "--frame-pointers", "--function-sections",
                "--forbid-trap", "--regions", "--device-semantics-file",
                "$(KERNEL_DEVICE_SEMANTICS)")
EXEMPT_DEFINES = {
    # EL0 user payloads: separate programs linked into the image as data,
    # not kernel sources; they take no kernel regions or device semantics.
    "KERNEL_EL0_COMPILE",
}
KERNEL_MARK = re.compile(r"\$\((QEMU|RPI5)_TARGET\)|\$\(KERNEL_\w+_(TKB|SRCS)\)"
                         r"|\$<|(^|[\s/])kernel/\S+\.tkb")
SCRIPT_FORBIDDEN = ('"--forbid-trap"', "'--forbid-trap'", '"--regions"', "'--regions'",
                    "--device-semantics-file", "aarch64-none-elf")


def logical_lines(text):
    """(first line number, joined text) per backslash-continued line."""
    out, buf, start = [], "", 0
    for number, line in enumerate(text.split("\n"), 1):
        if not buf:
            start = number
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        out.append((start, buf + line))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def flag_vars(lines):
    """KERNEL_*_FLAGS variables whose definition reaches a platform variable."""
    found = set()
    for _, line in lines:
        m = re.match(r"(KERNEL_\w+_FLAGS)\s*:?=(.*)", line)
        if m and any(v in m.group(2) for v in PLATFORM_VARS):
            found.add(f"$({m.group(1)})")
    return found


def is_invocation(line):
    """A recipe line running the compiler; prerequisite lists only name it."""
    return line.startswith("\t") and "$(TAKIBI)" in line


def makefile_problems(text):
    lines = logical_lines(text)
    shared = set(PLATFORM_VARS) | flag_vars(lines)
    problems, define, examined = [], None, 0
    for number, line in lines:
        head = line.strip()
        if head.startswith("define "):
            define = head.split()[1]
            continue
        if head == "endef":
            define = None
            continue
        if re.match(r"KERNEL_\w+_FLAGS\s*:?=", line) and any(v in line for v in PLATFORM_VARS):
            examined += 1
            problems += respelled_problems(number, line)
            continue
        if not is_invocation(line) or "LINUX_AMD64_TARGET" in line:
            continue
        uses = any(v in line for v in shared)
        if not uses and not KERNEL_MARK.search(line):
            continue
        if define in EXEMPT_DEFINES:
            continue
        examined += 1
        if not uses:
            problems.append(f"Makefile:{number}: kernel compile without "
                            "$(KERNEL_QEMU_COMPILE_FLAGS) or $(KERNEL_RPI5_COMPILE_FLAGS)")
        problems += respelled_problems(number, line)
    return problems, examined


def respelled_problems(number, line):
    respelled = [f for f in SHARED_FLAGS
                 if re.search(re.escape(f) + r"(?=[\s=]|$)", line)]
    if not respelled:
        return []
    return [f"Makefile:{number}: kernel compile spells shared flag(s) "
            f"{', '.join(respelled)}; take them from KERNEL_COMPILE_FLAGS"]


def kernel_scripts(text):
    return sorted(set(re.findall(r"python3 (scripts/\w+\.py) \$\(KERNELBUILD_CHECK_ARGS\)", text)))


def script_problems(name, text):
    problems = []
    if "kernel_compile_flags()" not in text:
        problems.append(f"{name}: compiles kernel sources without kernel_compile_flags()")
    for literal in SCRIPT_FORBIDDEN:
        if literal in text:
            problems.append(f"{name}: spells {literal}; take it from kernel_compile_flags()")
    return problems


def problems_in(makefile, scripts):
    problems, examined = makefile_problems(makefile)
    for name, text in scripts.items():
        problems += script_problems(name, text)
    return problems, examined


def main():
    makefile = (ROOT / "Makefile").read_text(encoding="ascii")
    names = kernel_scripts(makefile)
    scripts = {n: (ROOT / n).read_text(encoding="ascii") for n in names}
    problems, examined = problems_in(makefile, scripts)
    for problem in problems:
        print(f"ERROR\tkernel-compile-flags: {problem}")
    if problems:
        print("FAIL kernel-compile-flags")
        return 1
    report_pass("kernel-compile-flags",
                f"{examined} Makefile kernel compile invocations and "
                f"{len(scripts)} kernel-compiling scripts take KERNEL_COMPILE_FLAGS",
                invocations=examined, scripts=len(scripts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
