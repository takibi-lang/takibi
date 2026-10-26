#!/usr/bin/env python3
"""A target that depends on a locked kernel build names no other prerequisite.

GitHub issue #1154. kernelbuild-qemu and kernelbuild-rpi5 run their build in a
sub-make under the kernel build lock ($(KERNEL_BUILD_LOCK_RUN) $(MAKE) ...).
kernelsh-qemu listed $(KERNEL_SHELL_EXT2_IMAGE) beside kernelbuild-qemu, so
after `make clean` the outer make built ext2.img outside the lock while the
locked sub-make built it too; one recipe truncated the other's ext2.img.tmp
("Bad magic number in super-block") and the first `make kernelsh-qemu` never
reached the shell. churn-qemu and churn-long-qemu had the same shape.

The rule: a rule whose prerequisites include kernelbuild-qemu,
kernelbuild-rpi5 or kernelbuild-check names no other normal prerequisite.
Further products are built in the recipe through
$(KERNEL_BUILD_LOCK_RUN) $(MAKE) <product>, as load-qemu does. .PHONY and
order-only prerequisites are not concerned. Lexical; the controls plant the
racing shape and the locked one.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCKED = ("kernelbuild-qemu", "kernelbuild-rpi5", "kernelbuild-check")
RULE = re.compile(r"^([^\t#=][^=:]*?)\s*:(?![:=])\s*(.*)$")


def rules(text: str):
    """(line number, targets, normal prerequisites) per rule line."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        start = i
        line = lines[i]
        while line.endswith("\\") and i + 1 < len(lines):
            i += 1
            line = line[:-1] + " " + lines[i].strip()
        i += 1
        if line.startswith("\t"):
            continue
        match = RULE.match(line)
        if not match:
            continue
        targets = match.group(1).split()
        if targets and targets[0] == ".PHONY":
            continue
        normal = match.group(2).split("|")[0].split(";")[0].split()
        yield start + 1, targets, normal


def problems_in(text: str) -> list:
    found = []
    for number, targets, normal in rules(text):
        if any(p in LOCKED for p in normal):
            others = [p for p in normal if p not in LOCKED]
            if others:
                found.append(
                    f"Makefile:{number}: {' '.join(targets)} depends on a "
                    f"locked kernel build and also on {' '.join(others)}; "
                    "build those in the recipe with "
                    "$(KERNEL_BUILD_LOCK_RUN) $(MAKE)")
    return found


def control() -> bool:
    good = ("kernelsh-qemu: kernelbuild-qemu\n"
            "\t@$(KERNEL_BUILD_LOCK_RUN) $(MAKE) $(KERNEL_SHELL_EXT2_IMAGE)\n"
            "kernelbuild-qemu: build\n"
            ".PHONY: kernelbuild-qemu kernelsh-qemu\n"
            "x: kernelbuild-rpi5 | $(DIR)\n")
    racing = "kernelsh-qemu: kernelbuild-qemu $(KERNEL_SHELL_EXT2_IMAGE)\n\t@run\n"
    continued = "churn: kernelbuild-qemu \\\n\t$(KERNEL_SHELL_EXT2_IMAGE)\n\t@run\n"
    rpi5 = "y: kernelbuild-rpi5 img\n"
    return (not problems_in(good)
            and all(len(problems_in(t)) == 1 for t in (racing, continued, rpi5)))


def main() -> int:
    if not control():
        print("FAIL locked-build-prereqs: the control plants a prerequisite "
              "beside a locked kernel build and the check did not refuse it "
              "(or refused the locked form)", file=sys.stderr)
        return 1
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    problems = problems_in(text)
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("FAIL locked-build-prereqs: a product built both outside and "
              "inside the kernel build lock races itself (#1154)",
              file=sys.stderr)
        return 1
    count = sum(1 for _, _, normal in rules(text)
                if any(p in LOCKED for p in normal))
    report_pass("locked-build-prereqs",
                f"{count} rule(s) depend on a locked kernel build and name "
                "nothing else beside it", rules=count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
