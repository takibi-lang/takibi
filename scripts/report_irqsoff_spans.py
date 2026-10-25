#!/usr/bin/env python3
"""Report the longest IRQ-masked span per lock class from a boot log.

GitHub issue #958. From the first lock of the boot until the boot report,
the kernel's standing irqsoff sampler (kernel/kernel/profile_session.tkb)
times every outermost mutex_irq_save/restore span on each core. The boot
report prints, per core,

    RECORDED irqsoff: cpu=C longest=T freq=F
    RECORDED irqsoff class: cpu=C ticks=T to 0xA 0xB 0xC

where a class is the chain of return addresses (innermost first, 0 where
the frame walk stopped) at which a span closed. This script symbolizes the
chains against the kernel ELF, folds each to its CLASS -- the first function
outside the lock wrappers (WRAPPER below) -- merges the cores, and prints the
longest span per class, longest first.

It is a report, not a verdict: no threshold is judged here, because no
baseline exists yet (#958 asks for the number to be visible). It fails only
when the measurement is missing or malformed, since a report that cannot see
its lines would otherwise stay silent forever.

Also printed, when the boot carries `irq mask cost:` lines (#920's probe),
the sampler's own cost per mask pair: least `sampled` minus least `pmr`.

Controls: scripts/check_report_irqsoff_spans_controls.py.
"""

import argparse
import bisect
import re
import subprocess
import sys

from pass_line import report_pass

CORE_LINE = re.compile(r"RECORDED irqsoff: cpu=(\d+) longest=(\d+) freq=(\d+)\s*$")
CLASS_LINE = re.compile(
    r"RECORDED irqsoff class: cpu=(\d+) ticks=(\d+) to((?: 0x[0-9a-f]+)+)\s*$")
COST_LINE = re.compile(
    r"irq mask cost: sample=\d+ rounds=(\d+) pmr=(\d+) daif=\d+ "
    r"sampled=(\d+) frequency=(\d+)\s*$")
# The lock wrappers a span closes through; the class is the first frame
# outside them.
WRAPPER = re.compile(r"^(mutex_|pool_lock_|irqsoff_)")


class Symbols:
    """Function containing an address, from `nm -n` of the kernel ELF."""

    def __init__(self, elf: str, nm: str = "nm"):
        out = subprocess.run([nm, "-n", elf], capture_output=True, text=True,
                             check=True).stdout
        self.starts = []
        self.names = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[1] in "tTwW":
                self.starts.append(int(parts[0], 16))
                self.names.append(parts[2])

    def name(self, address: int) -> str:
        index = bisect.bisect_right(self.starts, address) - 1
        if index < 0:
            return f"0x{address:x}"
        return self.names[index]


def parse(text: str):
    """(cores, classes, costs) from the log; raise ValueError on a conflict."""
    cores = {}
    classes = []
    costs = []
    for raw in text.replace("\r", "").splitlines():
        line = re.sub(r"^\[\d+\.\d+\] ", "", raw)
        match = CORE_LINE.search(line)
        if match:
            cpu = int(match.group(1))
            record = (int(match.group(2)), int(match.group(3)))
            if cores.get(cpu, record) != record:
                raise ValueError(f"cpu{cpu} reported twice with different numbers")
            cores[cpu] = record
            continue
        match = CLASS_LINE.search(line)
        if match:
            pcs = tuple(int(word, 16) for word in match.group(3).split())
            entry = (int(match.group(1)), int(match.group(2)), pcs)
            if entry not in classes:
                classes.append(entry)
            continue
        if line.startswith("RECORDED irqsoff"):
            raise ValueError(f"malformed line: {line.strip()}")
        match = COST_LINE.search(line)
        if match:
            costs.append(tuple(int(match.group(i)) for i in range(1, 5)))
    for cpu, _ticks, _pcs in classes:
        if cpu not in cores:
            raise ValueError(f"class line for cpu{cpu} without its core line")
    return cores, classes, costs


def chain(pcs, symbols):
    names = []
    for pc in pcs:
        if pc == 0:
            break
        names.append(symbols.name(pc - 4))
    return names


def class_of(names) -> str:
    for name in names:
        if not WRAPPER.match(name):
            return name
    return names[-1] + " (wrappers only)" if names else "(no frames)"


def fold(classes, symbols):
    """Per class: (max ticks, cpu, chain), merged over cores."""
    merged = {}
    for cpu, ticks, pcs in classes:
        names = chain(pcs, symbols)
        key = class_of(names)
        if key not in merged or ticks > merged[key][0]:
            merged[key] = (ticks, cpu, names)
    return merged


def report(text: str, symbols, label: str) -> int:
    try:
        cores, classes, costs = parse(text)
    except ValueError as error:
        print(f"FAIL irqsoff-spans: {error}", file=sys.stderr)
        return 1
    if not cores:
        print("FAIL irqsoff-spans: no `RECORDED irqsoff: cpu=...` line; the "
              "boot report's standing sampler (#958) printed nothing",
              file=sys.stderr)
        return 1
    freq = next(iter(cores.values()))[1]
    for cpu in sorted(cores):
        ticks = cores[cpu][0]
        print(f"[{label}] irqsoff cpu{cpu}: longest {ticks} ticks "
              f"= {ticks / freq * 1e6:.1f} us")
    merged = fold(classes, symbols)
    for key, (ticks, cpu, names) in sorted(merged.items(),
                                           key=lambda item: -item[1][0]):
        print(f"[{label}] irqsoff class {key}: {ticks} ticks "
              f"= {ticks / freq * 1e6:.1f} us (cpu{cpu}; "
              f"{' <- '.join(names) or 'no frames'})")
    if costs:
        rounds = costs[0][0]
        pmr = min(cost[1] for cost in costs)
        sampled = min(cost[2] for cost in costs)
        cost_freq = costs[0][3]
        print(f"[{label}] irqsoff sampler cost: "
              f"{(sampled - pmr) / rounds / cost_freq * 1e9:.1f} ns per mask "
              f"pair (least of {len(costs)} samples, {rounds} pairs each)")
    report_pass("irqsoff-spans",
                f"{len(cores)} core(s), {len(merged)} lock class(es) reported",
                cores=len(cores), classes=len(merged))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log")
    parser.add_argument("--elf", required=True)
    parser.add_argument("--nm", default="nm")
    parser.add_argument("--label", default="kernel")
    args = parser.parse_args()
    with open(args.log, "rb") as handle:
        text = handle.read().decode("utf-8", "replace")
    return report(text, Symbols(args.elf, args.nm), args.label)


if __name__ == "__main__":
    sys.exit(main())
