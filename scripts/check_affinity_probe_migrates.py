#!/usr/bin/env python3
"""The affinity probe's example syscall must stay OUTSIDE the peer-safe table.

GitHub issue #9's migration gate is watched by `kernelcheck-affinity-gdb-qemu`:
`/bin/affinity` pins itself to CPU 1 and issues one syscall the kernel refuses
to run there, and gdb watches the gate rewind it and core 0 rerun it. The
whole lane rests on that syscall being one `syscall_peer_safe` does not
admit.

Phase B entry 6 is a sequence of widenings of exactly that table, and the
first of them admitted `uname` -- which is the syscall the probe was using.
Nothing said so. The lane failed instead, after a full QEMU boot, with a
message about the gate not firing, which reads like a defect in the gate
rather than a falsified premise in its own fixture.

So the two numbers are held together here, in a check that reads tracked
files and finishes instantly:

  - `kernel/arch/arm64/kernel/affinity_probe.tkb` declares the number it
    issues, and prints a line naming the syscall;
  - `scripts/kernel_affinity_gdb_check.py` watches for that same number in
    the rewound frame;
  - `kernel/kernel/syscall.tkb`'s refusal list, `syscall_peer_refused`,
    must name it. Since GitHub issue #583 the table is a refusal list: a
    syscall it does not name runs wherever it is called.

The third is the point; the first two are what makes the third meaningful,
since a probe and a watcher that disagreed would make the lane pass for the
wrong reason.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROBE = ROOT / "kernel" / "arch" / "arm64" / "kernel" / "affinity_probe.tkb"
WATCHER = ROOT / "scripts" / "kernel_affinity_gdb_check.py"
SYSCALL = ROOT / "kernel" / "kernel" / "syscall.tkb"


def probe_syscall(text):
    """(number, name) the probe issues to make the gate fire.

    Derived from the sentence the probe prints, not from the first constant
    in the file: the printed line is what a person reads out of a capture,
    so it is the right thing for the rest to be held to.
    """
    said = re.search(
        r'affinity_say\(bs"affinity: pinned to cpu 1, where (\w+), outside '
        r'the peer-safe table, still answered', text)
    if said is None:
        raise ValueError(
            "affinity_probe.tkb no longer prints the pinned line naming the "
            "syscall it migrated; this check reads that name and it has moved")
    name = said.group(1).upper()
    declared = re.search(rf"^const {name}_SYSCALL: usize = (\d+);$", text, re.M)
    if declared is None:
        raise ValueError(
            f"the probe says it issued `{said.group(1)}` and declares no "
            f"`const {name}_SYSCALL`: one of the two was renamed alone")
    if f"svc5({name}_SYSCALL," not in text:
        raise ValueError(
            f"{name}_SYSCALL is declared and never passed to svc5: the probe "
            f"would make the gate fire on something else")
    return int(declared.group(1)), name


def watched_syscall(text):
    found = re.search(r"^MIGRATED_SYSCALL = (\d+)$", text, re.M)
    if found is None:
        raise ValueError(
            "kernel_affinity_gdb_check.py no longer names MIGRATED_SYSCALL, "
            "so nothing says which syscall the gate is watched for")
    return int(found.group(1))


def refused_numbers(text):
    """Every number `syscall_peer_refused` compares `number` against."""
    body = re.search(r"fn syscall_peer_refused\(.*?\n\}", text, re.DOTALL)
    if body is None:
        raise ValueError("syscall_peer_refused is missing or reshaped")
    literals = {int(n) for n in re.findall(r"number == (\d+)", body.group(0))}
    for low, high in re.findall(r"number >= (\d+) && number <= (\d+)",
                                body.group(0)):
        literals.update(range(int(low), int(high) + 1))
    named = set()
    for constant in re.findall(r"number == (AARCH64_NR_\w+)", body.group(0)):
        value = re.search(rf"const {constant}: usize = (\d+);", text)
        if value is None:
            raise ValueError(f"{constant} is compared and never defined")
        named.add(int(value.group(1)))
    return literals | named


def main() -> int:
    try:
        number, name = probe_syscall(PROBE.read_text(encoding="ascii"))
        watched = watched_syscall(WATCHER.read_text(encoding="ascii"))
        refused = refused_numbers(SYSCALL.read_text(encoding="ascii"))
    except (OSError, ValueError) as error:
        print(f"FAIL affinity-probe-migrates: {error}")
        return 1

    problems = []
    if watched != number:
        problems.append(
            f"the probe issues {name}_SYSCALL ({number}) and the gdb watcher "
            f"waits for {watched}: the lane would pass only if some other "
            f"syscall happened to migrate")
    if number not in refused:
        problems.append(
            f"syscall_peer_refused does not name {number}, which is the "
            f"syscall /bin/affinity issues to make the migration gate fire "
            f"({name}_SYSCALL): the lane's premise is false, so pick a "
            f"syscall the refusal list still names")

    if problems:
        for problem in problems:
            print(f"ERROR\taffinity-probe-migrates: {problem}")
        print(f"FAIL affinity-probe-migrates: {len(problems)} thing(s) the "
              f"affinity gdb lane rests on are no longer true")
        return 1
    report_pass("affinity-probe-migrates",
                f"the affinity probe, its gdb watcher and the refusal list "
                f"agree that {name}_SYSCALL ({number}) migrates, one of "
                f"{len(refused)} syscall(s) the list keeps on core 0",
                refused=len(refused))
    return 0


if __name__ == "__main__":
    sys.exit(main())
