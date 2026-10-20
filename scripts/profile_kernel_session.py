#!/usr/bin/env python3
"""Capture and fold a kernel sampling profile (GitHub issue #497).

The kernel side is kernel/kernel/profile_session.tkb: writing
`start [PERIOD] [SAMPLES] [DEPTH]` to /proc/takibi/profile arms every
core's PMU cycle counter, `stop` disarms it, and DDB's `profile dump`
prints every sample as

  profile-session: sample cpu=C t=HEX pid=P el=0|1 skid=N stop=S pcs=HEX,...

pcs[0] is the interrupted PC, the rest are return addresses from the
frame-pointer chain (EL1 only). The skid is how many cycles the counter had
run past its overflow when the interrupt was taken: a sample delivered late
because IRQs were masked stands for 1 + skid // period periods.

Subcommands:

  capture  boot a tree's interactive shell kernel (QEMU or RPi5), start a
           session, run a workload (HTTP fetches from the host and/or a shell
           command), stop, break into DDB, dump, continue; save the console.
  check    assert what a capture must show: every interrupt accounted,
           named cores sampled, optionally a function among the top frames.
  fold     parse a saved console, symbolize against the kernel ELF, and
           write folded stacks ("frame;frame;leaf weight" per line, the
           input of flamegraph.pl / speedscope), plus a summary: total and
           masked (late) weight, EL0 vs EL1, and the top functions by
           inclusive weight.

Usage:
  profile_kernel_session.py capture --target rpi5 [--root TREE]
      [--start "start 240000 2048 16"] [--http N] [--http-path /bin/x]
      [--command "ls -R /"] --out DIR
  profile_kernel_session.py fold --elf kernel/build/rpi5/kernel-shell.elf
      --console DIR/console.log [--out DIR/kernel.folded] [--top 15]

The irqsoff tracer (GitHub issue #811) adds to each `cpuN` line of
/proc/takibi/profile the longest span, in generic-counter ticks, that the
core spent with IRQs masked by mutex_irq_save while the session sampled,
and three return addresses of the caller chain where it opened and closed:

  cpuN stored S lost L irqsoff_ticks T from 0xA 0xB 0xC to 0xD 0xE 0xF

`fold` prints them symbolized (innermost first; 0 means the walk stopped),
and `check --expect-irqsoff` requires a measured span whose two sites
symbolize to kernel functions.

A late sample (skid past one period) folds as its stack with weight 1 plus
the same stack under a "[masked]" leaf with the rest: the leaf of a late
sample is where IRQs came back on, so masked time shows up at the end of
the region that masked them (its unlock), not inside the function that ran
there. EL0 samples fold as "[el0 pid=P]" with their PC; the user binary is not
symbolized here. An EL1 sample's frames are symbolized to the function
containing each address (a return address is looked up at address - 4).
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
from pathlib import Path
import pty
import re
import subprocess
import sys
import time
import urllib.request

HERE = Path(__file__).resolve().parent

SAMPLE_RE = re.compile(
    r"profile-session: sample cpu=(\d+) t=([0-9a-f]+) pid=(\d+) el=([01]) "
    r"skid=(\d+) stop=(\d+) pcs=([0-9a-f,]+)")
BEGIN_RE = re.compile(r"profile-session: begin period=(\d+) depth=(\d+)")
END_RE = re.compile(r"profile-session: end samples=(\d+) lost=(\d+)")
CORE_RE = re.compile(
    r"profile-session: core cpu=(\d+) stored=(\d+) lost=(\d+) capacity=(\d+) "
    r"interrupts=(\d+) unbuffered=(\d+) arms=(\d+)")
STOP_NAMES = {0: "complete", 1: "depth", 2: "range", 3: "user", 4: "return"}


# -- fold ---------------------------------------------------------------

def parse_console(text: str):
    """(period, samples, end) from one dump; refuses a dump with no end."""
    begins = BEGIN_RE.findall(text)
    if not begins:
        raise ValueError("no 'profile-session: begin' line in the console")
    period = int(begins[-1][0])
    if period <= 0:
        raise ValueError("profile period is zero")
    start = text.rfind("profile-session: begin")
    body = text[start:]
    end = END_RE.search(body)
    if end is None:
        raise ValueError("dump has no 'profile-session: end' line (truncated?)")
    samples = []
    for match in SAMPLE_RE.finditer(body[:end.start()]):
        cpu, stamp, pid, el, skid, stop, pcs = match.groups()
        samples.append({
            "cpu": int(cpu), "t": int(stamp, 16), "pid": int(pid),
            "el": int(el), "skid": int(skid), "stop": int(stop),
            "pcs": [int(pc, 16) for pc in pcs.split(",") if pc],
        })
    declared = int(end.group(1))
    if declared != len(samples):
        raise ValueError(f"dump declares {declared} samples, parsed {len(samples)}")
    samples.sort(key=lambda sample: sample["t"])
    return period, samples, {"declared": declared, "lost": int(end.group(2))}


IRQSOFF_RE = re.compile(
    r"^cpu(\d+) stored \d+ lost \d+ irqsoff_ticks (\d+) "
    r"from ((?:0x[0-9a-f]+ ?)+)to((?: 0x[0-9a-f]+)+)\s*$", re.M)


def irqsoff_records(text: str) -> dict:
    """The last /proc/takibi/profile read's irqsoff fields, by cpu."""
    cores = {}
    for match in IRQSOFF_RE.finditer(text):
        cores[int(match.group(1))] = {
            "ticks": int(match.group(2)),
            "from": [int(word, 16) for word in match.group(3).split()],
            "to": [int(word, 16) for word in match.group(4).split()],
        }
    return cores


def irqsoff_sites(pcs, symbols) -> list[str]:
    """Return addresses symbolized at address - 4, up to the first 0."""
    names = []
    for pc in pcs:
        if pc == 0:
            break
        names.append(symbols.name(pc - 4))
    return names


def weight_of(sample, period: int) -> int:
    return 1 + sample["skid"] // period


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


def fold(samples, period: int, symbols) -> tuple[dict, dict]:
    stacks: dict[str, int] = {}
    summary = {"samples": len(samples), "weight": 0, "masked_weight": 0,
               "el0_weight": 0, "el1_weight": 0, "stops": {}, "inclusive": {},
               "self": {}}
    for sample in samples:
        weight = weight_of(sample, period)
        summary["weight"] += weight
        if weight > 1:
            summary["masked_weight"] += weight - 1
        if sample["el"] == 0:
            summary["el0_weight"] += weight
            frames = [f"[el0 pid={sample['pid']}]"]
        else:
            summary["el1_weight"] += weight
            frames = []
            for depth, pc in enumerate(sample["pcs"]):
                frames.append(symbols.name(pc if depth == 0 else pc - 4))
            frames.reverse()
            frames.insert(0, "[el1]")
        stop = STOP_NAMES.get(sample["stop"], str(sample["stop"]))
        summary["stops"][stop] = summary["stops"].get(stop, 0) + 1
        key = ";".join(frames)
        # A late sample's extra weight is time IRQs were masked; it hangs
        # under a [masked] leaf at the unmask point, so a flame graph shows
        # how much of a function's width is masked time.
        stacks[key] = stacks.get(key, 0) + 1
        if weight > 1:
            masked_key = key + ";[masked]"
            stacks[masked_key] = stacks.get(masked_key, 0) + weight - 1
        for name in set(frames):
            summary["inclusive"][name] = summary["inclusive"].get(name, 0) + weight
        summary["self"][frames[-1]] = summary["self"].get(frames[-1], 0) + weight
    return stacks, summary


def cmd_fold(args) -> int:
    text = Path(args.console).read_text(encoding="ascii", errors="replace")
    text = text.replace("\r", "")
    period, samples, end = parse_console(text)
    symbols = Symbols(args.elf, args.nm)
    stacks, summary = fold(samples, period, symbols)
    out = Path(args.out) if args.out else Path(args.console).with_suffix(".folded")
    out.write_text("".join(f"{key} {value}\n"
                           for key, value in sorted(stacks.items())))
    summary["period"] = period
    summary["lost"] = end["lost"]
    top_inclusive = sorted(summary["inclusive"].items(), key=lambda kv: -kv[1])
    top_self = sorted(summary["self"].items(), key=lambda kv: -kv[1])
    summary["top_inclusive"] = top_inclusive[:args.top]
    summary["top_self"] = top_self[:args.top]
    del summary["inclusive"], summary["self"]
    Path(str(out) + ".json").write_text(json.dumps(summary, indent=2) + "\n")
    total = summary["weight"] or 1
    print(f"[profile] samples={summary['samples']} lost={summary['lost']} "
          f"weight={summary['weight']} masked={summary['masked_weight']} "
          f"({100 * summary['masked_weight'] / total:.1f}%) "
          f"el1={summary['el1_weight']} el0={summary['el0_weight']} "
          f"stops={summary['stops']}")
    print("[profile] top inclusive:")
    for name, value in summary["top_inclusive"]:
        print(f"  {100 * value / total:5.1f}%  {value:6d}  {name}")
    print("[profile] top self:")
    for name, value in summary["top_self"]:
        print(f"  {100 * value / total:5.1f}%  {value:6d}  {name}")
    for cpu, core in sorted(irqsoff_records(text).items()):
        print(f"[profile] irqsoff cpu{cpu} ticks={core['ticks']} from "
              + " <- ".join(irqsoff_sites(core["from"], symbols) or ["?"])
              + " to "
              + " <- ".join(irqsoff_sites(core["to"], symbols) or ["?"]))
    print(f"[profile] folded stacks: {out}")
    return 0


def core_records(text: str) -> dict:
    """Per-core accounting lines of the last dump, by cpu."""
    start = text.rfind("profile-session: begin")
    cores = {}
    for match in CORE_RE.finditer(text[start:]):
        cpu, stored, lost, capacity, interrupts, unbuffered, arms = map(int, match.groups())
        cores[cpu] = {"stored": stored, "lost": lost, "capacity": capacity,
                      "interrupts": interrupts, "unbuffered": unbuffered,
                      "arms": arms}
    return cores


def check_console(text: str, require_cores, expect_function, symbols,
                  expect_irqsoff: bool = False) -> list[str]:
    """What a capture must show; returns the problems, empty when it passes.

    - every core is accounted: each interrupt it took was stored, lost or
      unbuffered (an interrupt the sampler never saw would not be counted
      at all, which is what a misrouted line looked like);
    - each required core armed and stored samples (#497: a secondary whose
      dispatch skipped the sampler stored none while its line stormed);
    - optionally, a function is among the top inclusive EL1 frames;
    - optionally (#811), some core measured an IRQ-off span, and both its
      innermost open and close sites symbolize to a kernel function.
    """
    problems = []
    period, samples, _end = parse_console(text)
    cores = core_records(text)
    if not cores:
        problems.append("no per-core accounting lines")
    for cpu, core in sorted(cores.items()):
        if core["interrupts"] != core["stored"] + core["lost"] + core["unbuffered"]:
            problems.append(f"cpu{cpu}: interrupts {core['interrupts']} != stored+lost+unbuffered")
    for cpu in require_cores:
        core = cores.get(cpu)
        if core is None or core["arms"] == 0 or core["stored"] == 0:
            problems.append(f"cpu{cpu}: armed and stored nothing ({core})")
    if expect_function:
        _stacks, summary = fold(samples, period, symbols)
        top = sorted(summary["inclusive"].items(), key=lambda kv: -kv[1])
        names = [name for name, _ in top if not name.startswith("[")][:10]
        if expect_function not in names:
            problems.append(f"{expect_function} is not in the top EL1 frames {names}")
    if expect_irqsoff:
        measured = [core for core in irqsoff_records(text).values()
                    if core["ticks"] > 0]
        if not measured:
            problems.append("no core measured an irqsoff span")
        for core in measured:
            for end in ("from", "to"):
                names = irqsoff_sites(core[end], symbols)
                if not names or names[0].startswith("0x"):
                    problems.append(f"irqsoff {end} site does not symbolize: "
                                    f"{core[end]}")
    return problems


def cmd_check(args) -> int:
    text = Path(args.console).read_text(encoding="ascii", errors="replace").replace("\r", "")
    symbols = Symbols(args.elf, args.nm) if args.elf else None
    cores = [int(cpu) for cpu in args.require_cores.split(",") if cpu]
    problems = check_console(text, cores, args.expect_function, symbols,
                             args.expect_irqsoff)
    if problems:
        for problem in problems:
            print(f"FAIL profile-session: {problem}")
        return 1
    print(f"PASS profile-session: dump accounted for every interrupt; cores "
          f"{cores or 'none'} sampled"
          + (f"; {args.expect_function} is a top frame" if args.expect_function else "")
          + ("; an irqsoff span was measured and its sites symbolize"
             if args.expect_irqsoff else ""))
    return 0


# -- capture ------------------------------------------------------------

LISTENER = b"listener ready port=8080"
PROFILE_DONE = b"__PROFILE_DONE__"
BRIDGE_RE = re.compile(r"httpd bridge: (http://127\.0\.0\.1:\d+/)".encode())


def capture(args) -> int:
    sys.path.insert(0, str(HERE))
    from run_kernel_churn import Session, has_prompt, terminate
    from typed_marker import typed_marker

    root = Path(args.root).resolve()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    runner = ("scripts/run_kernel_shell_qemu.sh" if args.target == "qemu"
              else "scripts/run_kernel_shell_rpi5.sh")
    env_key = ("KERNEL_QEMU_SHELL_ARTIFACT_DIR" if args.target == "qemu"
               else "KERNEL_RPI5_SHELL_ARTIFACT_DIR")
    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(root)
        os.environ[env_key] = str(out / "runner")
        os.environ.pop("KERNEL_SHELL_TRANSCRIPT", None)
        os.execvp("bash", ["bash", runner])
    session = Session(pid, terminal, label="kernel/profile")
    status = 1
    try:
        if session.wait_for(lambda text: LISTENER in text and has_prompt(text)
                            or None, args.boot_seconds) is None:
            raise RuntimeError("shell did not come up")

        def shell(command: str, seconds: float = 120) -> str:
            start = len(session.normalized())
            session.send(command.encode() + b"; echo " +
                         typed_marker(PROFILE_DONE) + b"\n")
            if session.wait_for(lambda text: (b"\n" + PROFILE_DONE + b"\n") in text[start:]
                                or None, seconds) is None:
                raise RuntimeError(f"shell command did not finish: {command}")
            return session.normalized()[start:].decode("ascii", "replace")

        url = None
        if args.target == "qemu":
            found = BRIDGE_RE.search(bytes(session.transcript))
            url = found.group(1).decode() if found else None
        else:
            url = f"http://{os.environ.get('ETH_TEST_SUBNET', '192.168.20')}.2:8080/"
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for _ in range(args.warmup if url else 0):
            with opener.open(url + args.http_path.lstrip("/"), timeout=120) as reply:
                reply.read()
        print(shell(f"echo {args.start} > /proc/takibi/profile; "
                    "cat /proc/takibi/profile"), flush=True)
        time.sleep(0.1)
        timings = []
        workload_error = None
        try:
            for _ in range(args.http if url else 0):
                began = time.monotonic()
                with opener.open(url + args.http_path.lstrip("/"),
                                 timeout=args.http_seconds) as reply:
                    size = len(reply.read())
                timings.append({"bytes": size,
                                "seconds": time.monotonic() - began})
            if args.command:
                print(shell(args.command, args.command_seconds), flush=True)
            print(shell("echo stop > /proc/takibi/profile; "
                        "cat /proc/takibi/profile"), flush=True)
        except (OSError, RuntimeError) as error:
            # Break in anyway: the stopped machine says why the workload
            # stalled, and the samples taken so far are still dumped.
            workload_error = error
            print(f"[profile] workload failed: {error}; breaking in", flush=True)
        start = len(session.normalized())
        session.send(b"\x14b")
        if session.wait_for(lambda text: b"ddb> " in text[start:] or None,
                            60) is None:
            raise RuntimeError("DDB did not answer the BREAK")
        if workload_error is not None:
            for command in (b"intr", b"sched", b"ps", b"wait", b"bt cpu 0",
                            b"bt cpu 1", b"bt cpu 2", b"bt cpu 3",
                            b"profile stop"):
                mark = len(session.normalized())
                session.send(command + b"\n")
                session.wait_for(lambda text: b"ddb> " in text[mark:] or None, 30)
        dump_from = len(session.normalized())
        session.send(b"profile dump\n")
        if session.wait_for(lambda text: re.search(
                rb"profile-session: end samples=\d+ lost=\d+\n",
                text[dump_from:]) or None, args.dump_seconds) is None:
            raise RuntimeError("profile dump did not finish")
        session.send(b"continue\n")
        session.wait_for(lambda text: b"ddb: continuing" in text[dump_from:]
                         or None, 30)
        (out / "http.json").write_text(json.dumps(timings, indent=2) + "\n")
        status = 0 if workload_error is None else 2
    except RuntimeError as error:
        print(f"FAIL profile capture: {error}", file=sys.stderr)
    finally:
        (out / "console.log").write_bytes(bytes(session.transcript))
        session.send(b"\x1d")
        time.sleep(1)
        terminate(pid)
        os.close(terminal)
    print(f"[profile] console: {out / 'console.log'}")
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    cap = sub.add_parser("capture")
    cap.add_argument("--target", choices=("qemu", "rpi5"), required=True)
    cap.add_argument("--root", default=str(HERE.parent))
    cap.add_argument("--start", default="start 240000 2048 16")
    cap.add_argument("--http", type=int, default=0)
    cap.add_argument("--warmup", type=int, default=2)
    cap.add_argument("--http-path", default="/bin/busybox.static")
    cap.add_argument("--http-seconds", type=float, default=60)
    cap.add_argument("--command", default="")
    cap.add_argument("--command-seconds", type=float, default=300)
    cap.add_argument("--boot-seconds", type=float, default=1800)
    cap.add_argument("--dump-seconds", type=float, default=900)
    cap.add_argument("--out", required=True)
    fol = sub.add_parser("fold")
    fol.add_argument("--elf", required=True)
    fol.add_argument("--console", required=True)
    fol.add_argument("--out")
    fol.add_argument("--nm", default="nm")
    fol.add_argument("--top", type=int, default=15)
    chk = sub.add_parser("check")
    chk.add_argument("--console", required=True)
    chk.add_argument("--elf")
    chk.add_argument("--nm", default="nm")
    chk.add_argument("--require-cores", default="")
    chk.add_argument("--expect-function", default="")
    chk.add_argument("--expect-irqsoff", action="store_true")
    args = parser.parse_args()
    if args.action == "capture":
        return capture(args)
    if args.action == "check":
        return cmd_check(args)
    return cmd_fold(args)


if __name__ == "__main__":
    sys.exit(main())
