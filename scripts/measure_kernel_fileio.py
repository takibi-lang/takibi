#!/usr/bin/env python3
"""Time file-I/O syscall workloads in the maintained kernel's BusyBox shell.

GitHub issue #765: #203 stage 2 makes every read, write, sendfile, syslog and
getdents call zero-fill the per-CPU 1 KiB (KERNEL_BLOCK_SIZE) file staging
buffer once per call. This boots the interactive shell kernel of a source
tree (QEMU or RPi5), runs a fixed set of guest workloads under `busybox time`
several times, and fetches large files over HTTP from the host, so two trees
-- the parent of a change and the change -- can be compared run for run.

Workloads (guest side, each one `busybox time` interval):
  read-1k     10x `busybox cksum /bin/busybox.static`: 1 KiB reads (the kernel
              caps a file read at one block)
  copy-1b     `dd bs=1` /large.txt -> /mutable.txt: 1-byte read + write
              pairs, two fills per byte, the most fill-sensitive workload.
              (A pure 1-byte read loop through ash `read < file` hung on
              both targets, so there is none.)
  copy-1k     `dd bs=1024` busybox.static -> /mutable.txt (count bounded so
              the image does not fill)
              Both copy workloads are bound by the block device write (about
              36 ms per write on RPi5 USB, 2026-10-12), so they bound what a
              fill can matter to there, not the syscall path.
  (sendfile is exercised by the HTTP lane: a guest `cat > /dev/null` is
  bound by the ext2 write of /dev/null, a regular file on this image.)
  getdents    `ls -R /` (getdents64 over every directory)
Host side: HTTP GETs of /bin/busybox.static (the httpd / TCP lane).

Timing is BusyBox's wall clock (10 ms resolution) and host monotonic time for
HTTP. Nothing here reads the PMU, so the #649 kernel-work-in-counters problem
does not apply; noise is reported as the spread over rounds and boots.

Usage:
  measure_kernel_fileio.py --target qemu|rpi5 [--root TREE] [--boots N]
                           [--rounds N] [--http N] [--label NAME] --json FILE

--root is a source tree whose kernel is already built (`make
kernelbuild-qemu kernel/build/user/ext2-shell.img` or `make
kernelbuild-rpi5`); its own shell runner is used. The RPi5 runner takes the
board lease itself and overwrites the sacrificial USB drive, as kernelsh-rpi5
does. Compare two JSON files with `--compare A.json B.json`.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import pty
import re
import statistics
import sys
import time
import urllib.request

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from run_kernel_churn import Session, has_prompt, terminate  # noqa: E402
from typed_marker import typed_marker  # noqa: E402

LISTENER = b"listener ready port=8080"
DONE = b"__FILEIO_DONE__"
REAL_RE = re.compile(r"real\s+(?:(\d+)m\s*)?([0-9.]+)s")
BRIDGE_RE = re.compile(rb"httpd bridge: (http://127\.0\.0\.1:\d+/)")

WORKLOADS = [
    ("read-1k",
     "busybox time sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do busybox cksum "
     "/bin/busybox.static; done' >/dev/null"),
    ("copy-1b",
     "busybox time busybox dd if=/large.txt of=/mutable.txt bs=1 "
     "count=200 conv=notrunc"),
    ("copy-1k",
     "busybox time busybox dd if=/bin/busybox.static of=/mutable.txt "
     "bs=1024 count=32 conv=notrunc"),
    ("getdents",
     "busybox time sh -c 'for i in 1 2 3 4 5; do ls -R / >/dev/null; done'"),
]


def port_in_use(port):
    tag = ":%04X" % port
    for name in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = Path(name).read_text().splitlines()[1:]
        except OSError:
            continue
        if any(line.split()[1].endswith(tag) for line in lines):
            return True
    return False


def run_command(session, command, seconds):
    start = len(session.normalized())
    session.send(command.encode() + b"; echo " + typed_marker(DONE) + b"\n")
    marker = b"\n" + DONE + b"\n"

    def finished(text):
        tail = text[start:]
        if marker not in tail:
            return None
        return True if has_prompt(b"\n" + tail.split(marker, 1)[1]) else None

    answer = session.wait_for(finished, seconds)
    if answer is None:
        raise RuntimeError(f"command did not finish in {seconds}s: {command}")
    return session.normalized()[start:].decode("ascii", "replace")


def parse_real(output):
    found = REAL_RE.findall(output)
    if len(found) != 1:
        raise RuntimeError(f"expected one 'real' line, got {found!r}:\n{output}")
    minutes, seconds = found[0]
    return int(minutes or 0) * 60 + float(seconds)


def http_fetch(url, path, timeout=120):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    started = time.monotonic_ns()
    with opener.open(url + path.lstrip("/"), timeout=timeout) as response:
        body = response.read()
        if response.status != 200:
            raise RuntimeError(f"HTTP {response.status} for {path}")
    return len(body), (time.monotonic_ns() - started) / 1e9


def one_boot(args, root, boot, result):
    """Boot once; retry when the runner's port guard refuses a port.

    The previous boot's sockets linger in TIME_WAIT for about a minute and
    the runner's guard counts them as in use, so back-to-back boots of the
    same tree would otherwise fail at launch.
    """
    for attempt in range(args.port_retries + 1):
        try:
            return boot_and_measure(args, root, boot, result)
        except PortBusy:
            if attempt == args.port_retries:
                raise
            print("[fileio] a port is still in use; retrying in 70s", flush=True)
            time.sleep(70)


class PortBusy(RuntimeError):
    pass


def boot_and_measure(args, root, boot, result):
    env_dir = Path(args.artifacts) / f"boot-{boot}"
    env_dir.mkdir(parents=True, exist_ok=True)
    if args.target == "qemu":
        runner = "scripts/run_kernel_shell_qemu.sh"
        env_key = "KERNEL_QEMU_SHELL_ARTIFACT_DIR"
    else:
        runner = "scripts/run_kernel_shell_rpi5.sh"
        env_key = "KERNEL_RPI5_SHELL_ARTIFACT_DIR"
    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(root)
        os.environ[env_key] = str(env_dir)
        os.environ.pop("KERNEL_SHELL_TRANSCRIPT", None)
        os.execvp("bash", ["bash", runner])
    session = Session(pid, terminal, label="kernel/fileio")
    try:
        ready = session.wait_for(
            lambda text: LISTENER in text and has_prompt(text) or None,
            args.boot_seconds)
        if ready is None:
            if b"is already in use" in bytes(session.transcript):
                raise PortBusy("runner port guard refused a port")
            raise RuntimeError("shell did not come up: " +
                               bytes(session.transcript[-600:]).decode("ascii", "replace"))
        if args.target == "qemu":
            found = BRIDGE_RE.search(bytes(session.transcript))
            url = found.group(1).decode() if found else None
        else:
            url = f"http://{os.environ.get('ETH_TEST_SUBNET', '192.168.20')}.2:8080/"
        # Warm the page cache-free paths once (ext2 lookups, exec of busybox).
        run_command(session, WORKLOADS[0][1], args.command_seconds)
        # The first two fetches of a boot run 3-6x slower on RPi5 (0.6 s and
        # 1.2 s against about 0.2 s, 2026-10-12, every tree alike), so they
        # are warm-up, not samples.
        for _ in range(2 if url else 0):
            try:
                http_fetch(url, args.http_path)
            except OSError:
                pass
        for round_number in range(args.rounds):
            for name, command in ([] if args.no_guest else WORKLOADS):
                seconds = parse_real(run_command(session, command,
                                                 args.command_seconds))
                result["samples"].append({"boot": boot, "round": round_number,
                                          "workload": name, "seconds": seconds})
                print(f"[fileio] boot={boot} round={round_number} {name} "
                      f"{seconds:.2f}s", flush=True)
            if url:
                for _ in range(args.http):
                    try:
                        size, seconds = http_fetch(url, args.http_path)
                    except OSError as error:
                        # A failed fetch is recorded, not timed: the guest
                        # workloads of the same boot stay usable.
                        result.setdefault("http_errors", []).append(
                            {"boot": boot, "round": round_number,
                             "error": str(error)})
                        print(f"[fileio] boot={boot} round={round_number} "
                              f"http error {error}", flush=True)
                        continue
                    result["samples"].append({"boot": boot, "round": round_number,
                                              "workload": "http-" + Path(args.http_path).name,
                                              "seconds": seconds, "bytes": size})
                    print(f"[fileio] boot={boot} round={round_number} "
                          f"http {seconds:.3f}s {size}B", flush=True)
    finally:
        (env_dir / "terminal.log").write_bytes(bytes(session.transcript))
        session.send(b"\x1d")
        time.sleep(1)
        terminate(pid)
        os.close(terminal)


def summarize(samples):
    by = {}
    for sample in samples:
        by.setdefault(sample["workload"], []).append(sample["seconds"])
    out = {}
    for name, values in by.items():
        out[name] = {"n": len(values), "median": statistics.median(values),
                     "min": min(values), "max": max(values)}
    return out


def compare(paths):
    loaded = [json.loads(Path(path).read_text()) for path in paths]
    base = loaded[0]["summary"]
    header = "workload      " + "".join(f"{d['label'][:22]:>24}" for d in loaded)
    print(header)
    for name in base:
        row = f"{name:<14}"
        for data in loaded:
            item = data["summary"].get(name)
            if item is None:
                row += f"{'-':>24}"
                continue
            delta = (item["median"] / base[name]["median"] - 1) * 100
            cell = (f"{item['median']:.3f} [{item['min']:.2f}-{item['max']:.2f}] "
                    f"{delta:+.1f}%")
            row += f"{cell:>24}"
        print(row)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", choices=("qemu", "rpi5"))
    parser.add_argument("--root", default=str(HERE.parent))
    parser.add_argument("--boots", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--http", type=int, default=3)
    parser.add_argument("--label", default=None)
    parser.add_argument("--json")
    parser.add_argument("--artifacts", default=None)
    parser.add_argument("--boot-seconds", type=int, default=1800)
    parser.add_argument("--command-seconds", type=int, default=600)
    parser.add_argument("--http-path", default="/bin/busybox.static",
                        help="file the HTTP lane fetches (a small one times "
                             "the per-request cost)")
    parser.add_argument("--no-guest", action="store_true",
                        help="skip the guest workloads; HTTP only")
    parser.add_argument("--port-retries", type=int, default=5)
    parser.add_argument("--compare", nargs="+", metavar="JSON")
    args = parser.parse_args()
    if args.compare:
        compare(args.compare)
        return 0
    if not args.target or not args.json:
        parser.error("--target and --json are required unless --compare")
    root = Path(args.root).resolve()
    args.artifacts = args.artifacts or str(Path(args.json).with_suffix(""))
    result = {"label": args.label or str(root), "target": args.target,
              "root": str(root), "samples": []}
    for boot in range(args.boots):
        one_boot(args, root, boot, result)
        result["summary"] = summarize(result["samples"])
        Path(args.json).write_text(json.dumps(result, indent=2) + "\n")
    for name, item in result["summary"].items():
        print(f"[fileio] {name}: median {item['median']:.3f}s "
              f"min {item['min']:.3f} max {item['max']:.3f} n={item['n']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
