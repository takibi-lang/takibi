#!/usr/bin/env python3
"""A fail-stop entered after IRQs were unmasked restores the fault's registers.

The fail-stop evidence path (el1_exception_evidence_from_frame ->
crash_snapshot_capture) reads ESR_EL1, FAR_EL1, ELR_EL1 and SPSR_EL1 from the
registers. An IRQ taken at EL1 overwrites ELR_EL1 and SPSR_EL1 (and a nested
fault ESR and FAR). GitHub issue #1373 made the EL0 fault path call
kernel_el0_fault_dispatch with IRQs unmasked before PID 1's fail-stop, and a
land's oops lane then reported a kernel PC as PID 1's faulting ELR (found
after #1371's land). QEMU's gdbstub can neither write ELR_EL1 nor an MMIO
SGI register, so no lane can make the IRQ land there on demand; this check
refuses the shape instead.

Rule, per straight-line block of user_entry.S (label to label): a block that
unmasks IRQs (`msr DAIFClr, #0x2`) and then branches to
el1_exception_evidence_from_frame must write esr_el1, far_el1, elr_el1 and
spsr_el1 after its last call and before that branch.

Usage: check_el0_fault_evidence_registers.py [FILE]   (default: user_entry.S)
"""
import re
import sys

from pass_line import report_pass

DEFAULT = "kernel/arch/arm64/kernel/user_entry.S"
TARGET = "el1_exception_evidence_from_frame"
REGS = ("esr_el1", "far_el1", "elr_el1", "spsr_el1")
LABEL = re.compile(r"^\s*([.\w]+):")


def strip(line):
    return line.split("//")[0].strip()


def blocks(text):
    # Drop /* */ comments, then split at labels.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    cur, name = [], "<start>"
    for line in text.splitlines():
        m = LABEL.match(line)
        if m:
            yield name, cur
            cur, name = [], m.group(1)
            line = line[m.end():]
        s = strip(line)
        if s:
            cur.append(s)
    yield name, cur


def check(text):
    """(errors, judged): judged counts evidence branches after an unmask."""
    errors = []
    judged = 0
    for name, insns in blocks(text):
        unmasked = False
        restored = set()
        for ins in insns:
            low = ins.lower()
            if re.match(r"msr\s+daifclr\s*,\s*#0x2\b", low):
                unmasked = True
                restored = set()
            elif low.startswith("bl ") or low.startswith("blr "):
                restored = set()
            m = re.match(r"msr\s+(\w+)\s*,", low)
            if m and m.group(1) in REGS:
                restored.add(m.group(1))
            if re.match(r"b\s+" + TARGET + r"\b", ins) and unmasked:
                judged += 1
                missing = [r for r in REGS if r not in restored]
                if missing:
                    errors.append(f"{name}: branches to {TARGET} after unmasking IRQs "
                                  f"without restoring {', '.join(missing)}")
    return errors, judged


GOOD = """
.Lf:
    mrs x0, esr_el1
    msr DAIFClr, #0x2
    bl dispatch
    msr DAIFSet, #0x2
    msr esr_el1, x19
    msr far_el1, x20
    msr elr_el1, x2
    msr spsr_el1, x2
    b el1_exception_evidence_from_frame
"""
BAD = """
.Lf:
    msr DAIFClr, #0x2
    bl dispatch
    msr DAIFSet, #0x2
    b el1_exception_evidence_from_frame
"""
MASKED = """
.Lg:
    bl handle
    b el1_exception_evidence_from_frame
"""


def controls():
    ok = True
    for name, text, want in (("restored", GOOD, 0), ("unrestored", BAD, 1), ("masked", MASKED, 0)):
        got = len(check(text)[0])
        if got != want:
            print(f"FAIL el0-fault-evidence-registers control {name}: {got} error(s), expected {want}")
            ok = False
    return ok


def main(argv):
    path = argv[1] if len(argv) > 1 else DEFAULT
    errors, judged = check(open(path).read())
    for e in errors:
        print(f"ERROR el0-fault-evidence-registers: {path}: {e}")
    if errors:
        print("FAIL el0-fault-evidence-registers")
        return 1
    if not controls():
        return 1
    report_pass("el0-fault-evidence-registers",
                f"{path}: {judged} fail-stop branch(es) after an unmasked call "
                f"restore {', '.join(REGS)}; planted restored, unrestored and "
                "masked blocks are judged as expected",
                branches=judged)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
