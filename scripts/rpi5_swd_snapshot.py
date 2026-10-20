#!/usr/bin/env python3
"""Bounded SWD snapshot of every RPi5 core, taken before a serial BREAK.

GitHub issue #869. The QEMU lanes record every vCPU's PC, symbol, IRQ mask
and tick count before they break into DDB (scripts/kernel_console.gdb, #854).
The board lane had nothing of the kind: #855 needed temporary runner edits to
learn that all four cores sat in kernel_idle_loop with IRQs unmasked. This
halts each core over SWD, reads pc and cpsr, reads secondary_tick_count
through a core halted in EL1 (a CPU-side read, coherent with the caches the
counters live in), and resumes every core so the BREAK that follows still
finds a running kernel.

Every failure is written to the log rather than raised: this runs inside a
lane that has already failed, and a diagnostic must not replace its verdict.
"""

import argparse
import bisect
import re
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BCM2712_CFG = REPO_ROOT / "kernel" / "platform" / "rpi5" / "jtag" / "bcm2712.cfg"
CORES = 4
# OpenOCD's own outside bound. Halting four cores, eight register reads, one
# 32-byte read and four resumes take about two seconds at 1 MHz SWD.
OPENOCD_TIMEOUT = 20.0
TICK_SYMBOL = "secondary_tick_count"

# Tcl, so one OpenOCD session decides which halted core can do the memory
# read. A core halted in EL0 cannot touch a kernel address (DSCR.ERR, see
# scripts/rpi5_set_kernel_byte.sh), so the first core in EL1 or above reads.
TCL = r"""
init
set reader -1
for {set c 0} {$c < %(cores)d} {incr c} {
    targets bcm2712.cpu$c
    if {[catch {halt 1000} error]} { echo "swd: cpu=$c halt-error=[string map {"\n" " "} $error]" }
}
for {set c 0} {$c < %(cores)d} {incr c} {
    targets bcm2712.cpu$c
    if {[catch {set pc [reg pc]} error]} {
        echo "swd: cpu=$c reg-error=[string map {"\n" " "} $error]"
        continue
    }
    if {[catch {set cpsr [reg cpsr]} error]} {
        echo "swd: cpu=$c reg-error=[string map {"\n" " "} $error]"
        continue
    }
    echo "swd: cpu=$c pc=[lindex $pc end] cpsr=[lindex $cpsr end]"
    if {$reader < 0 && [scan [lindex $cpsr end] %%x value] == 1 && (($value >> 2) & 3) >= 1} {
        set reader $c
    }
}
if {$reader >= 0 && "%(ticks)s" ne ""} {
    targets bcm2712.cpu$reader
    if {[catch {set words [read_memory %(ticks)s 32 [expr {2 * %(cores)d}]]} error]} {
        echo "swd: ticks-error=[string map {"\n" " "} $error]"
    } else {
        echo "swd: ticks reader=$reader values=$words"
    }
} else {
    echo "swd: ticks-error=no core halted in EL1 or no tick symbol"
}
for {set c 0} {$c < %(cores)d} {incr c} {
    targets bcm2712.cpu$c
    if {[catch {resume} error]} { echo "swd: cpu=$c resume-error=[string map {"\n" " "} $error]" }
}
shutdown
"""


def symbols(elf):
    """Sorted (address, name) of the ELF's text symbols, and the tick address."""
    listing = subprocess.run(["llvm-nm-19", "-n", str(elf)], check=True,
                             capture_output=True, text=True, timeout=10).stdout
    table, ticks = [], None
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) != 3:
            continue
        address, kind, name = int(fields[0], 16), fields[1], fields[2]
        if kind in "tT":
            table.append((address, name))
        if name == TICK_SYMBOL:
            ticks = address
    return table, ticks


def symbolize(table, pc):
    at = bisect.bisect_right([address for address, _ in table], pc) - 1
    if at < 0:
        return "unknown"
    address, name = table[at]
    return f"{name}+{pc - address:#x}"


def parse(text, table):
    """The `swd:` lines OpenOCD echoed, as the console snapshot's lines."""
    lines, ticks = [], {}
    found = re.search(r"^swd: ticks reader=(\d+) values=(.*)$", text, re.M)
    if found:
        # Read as 32-bit halves: OpenOCD 0.12's `read_memory ADDR 64 N` read
        # 32-bit units with stale upper halves on this board (2026-10-20,
        # every count came back near 0x7efe00000000).
        words = [int(value, 0) for value in found.group(2).split()]
        for cpu in range(len(words) // 2):
            ticks[cpu] = words[2 * cpu] | (words[2 * cpu + 1] << 32)
    for match in re.finditer(r"^swd: cpu=(\d+) pc=(0x[0-9a-fA-F]+) "
                             r"cpsr=(0x[0-9a-fA-F]+)$", text, re.M):
        cpu, pc, cpsr = int(match.group(1)), int(match.group(2), 16), int(match.group(3), 16)
        daif = (cpsr >> 6) & 0xF
        lines.append(f"console: cpu cpu={cpu} pc={pc:#x} symbol={symbolize(table, pc)} "
                     f"cpsr={cpsr:#x} el={(cpsr >> 2) & 3} daif={daif:#x} "
                     f"irq_masked={bool(daif & 0x2)} ticks={ticks.get(cpu)}")
    for match in re.finditer(r"^swd: (cpu=\d+ \S+-error=.*|ticks-error=.*)$", text, re.M):
        lines.append("console: unavailable " + match.group(1))
    return lines


def capture(elf, output, phase, runner=subprocess.run):
    log = Path(output)
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="ascii") as stream:
        stream.write(f"swd snapshot phase: {phase}\nELF: {Path(elf).resolve()}\n")
        stream.flush()
        try:
            table, ticks = symbols(elf)
            with tempfile.NamedTemporaryFile("w", suffix=".tcl", encoding="ascii") as script:
                script.write(TCL % {"cores": CORES,
                                    "ticks": f"{ticks:#x}" if ticks is not None else ""})
                script.flush()
                result = runner(
                    ["openocd", "-f", "interface/cmsis-dap.cfg", "-f", str(BCM2712_CFG),
                     "-f", script.name],
                    capture_output=True, text=True, errors="replace",
                    timeout=OPENOCD_TIMEOUT)
            text = (result.stdout or "") + (result.stderr or "")
            lines = parse(text, table)
            stream.write("".join(line + "\n" for line in lines))
            stream.write("openocd transcript:\n" + text)
            if not any(line.startswith("console: cpu ") for line in lines):
                raise RuntimeError(f"OpenOCD exited {result.returncode} with no core read")
            stream.write("swd snapshot status: captured\n")
        except Exception as error:  # A diagnostic must preserve the lane verdict.
            stream.write(f"swd snapshot status: unavailable: {error}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--phase", default="manual")
    args = parser.parse_args()
    capture(args.elf, args.output, args.phase)


if __name__ == "__main__":
    main()
