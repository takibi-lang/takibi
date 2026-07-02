#!/usr/bin/env python3
"""
Rough PC sampler for a running QEMU AArch64 guest, driven over its gdbstub.

Run as: python3 profile_pc_sampler.py PORT OUTFILE NUM_SAMPLES
(see profile_http_server.py, the orchestrator that launches this alongside
QEMU and a load generator). Writes one hex address per line to OUTFILE.

Technique: spawn gdb-multiarch fresh for *each* sample and just
connect + print $pc + detach. This relies on two empirically-confirmed
QEMU gdbstub behaviors (verified interactively before writing this):
connecting halts the vCPU (so $pc is a real live snapshot, not garbage),
and detaching resumes it (so the guest keeps making progress between
samples, at whatever gdb-multiarch's own per-invocation overhead -- about
75ms, measured in this environment -- naturally spaces samples apart).

This is deliberately NOT built around a single long-lived gdb session with
`continue &` + `interrupt` (the classic in-process "poor man's profiler"
pattern): that was tried first and abandoned. gdb's Python `interrupt`
sends the stop request asynchronously and does not reliably transition
gdb's internal running/stopped bookkeeping to "stopped" within batch mode
(confirmed: is_running() stayed True even after polling for a full second),
so $pc reads kept failing with "Selected thread is running." The
per-sample-subprocess approach sidesteps that whole class of problem at
the cost of ~75ms of gdb startup overhead per sample -- acceptable for a
rough profiler that doesn't need more than a couple hundred samples.

Must run with gdb-multiarch, not stock gdb: stock gdb on this platform is
built --target=x86_64-linux-gnu only and cannot parse the AArch64
target-description XML QEMU sends over the remote protocol ("unknown
architecture aarch64" + truncated register errors). See CLAUDE.md's
Dependencies section for why gdb-multiarch is required.

Caveat shared with the rest of this profiling tool (see
profile_http_server.py's module docstring for the full explanation): QEMU's
TCG emulation doesn't model real Cortex-A53 pipeline/cache timing, so this
profile is directional (which function/line dominates), not a cycle count.
"""
import re
import subprocess
import sys

PC_RE = re.compile(r"\$1 = (0x[0-9a-fA-F]+)")


def sample_once(port: int):
    proc = subprocess.run(
        ["gdb-multiarch", "-batch", "-q",
         "-ex", "set confirm off",
         "-ex", "target remote localhost:%d" % port,
         "-ex", "print/x $pc",
         "-ex", "detach"],
        capture_output=True, text=True, timeout=5,
    )
    m = PC_RE.search(proc.stdout)
    return int(m.group(1), 16) if m else None


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: profile_pc_sampler.py PORT OUTFILE NUM_SAMPLES", file=sys.stderr)
        return 1
    port = int(sys.argv[1])
    outfile = sys.argv[2]
    num_samples = int(sys.argv[3])

    samples = []
    missed = 0
    for _ in range(num_samples):
        pc = sample_once(port)
        if pc is not None:
            samples.append(pc)
        else:
            missed += 1

    with open(outfile, "w") as f:
        for pc in samples:
            f.write("0x%x\n" % pc)

    print("PROFILE_SAMPLER: %d samples, %d missed" % (len(samples), missed), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
