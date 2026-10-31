#!/usr/bin/env python3
"""Keep one line of figures per green land, and say when one has moved.

GitHub issue #1287: the pool lock wait sum rose 2.5x in six days and nobody
saw it start, because each figure lived only in a log the next run replaced.

`record COMMIT ALLCHECK_LOG` is called by scripts/land.sh after a green
allcheck, before anything cleans _build. It appends one JSON line to
<git common dir>/takibi-land/figures.jsonl, outside tracked files because a
tracked per-land row would conflict on every rebase. It only reads what the
run already left: no measurement, no lane. It never fails or stops a land: a
value it cannot read is recorded as null, and any error still exits 0.

`compare` prints each figure whose median over the last WINDOW lands moved by
THRESHOLD_PERCENT or more against the WINDOW before them, and prints nothing
otherwise, including with too little history. Both numbers are provisional
(maintainer, 2026-10-31). A move is a question, not a verdict.

Controls: scripts/check_land_figures_controls.py.
"""

import json
import pathlib
import re
import statistics
import struct
import subprocess
import sys
import time

FIGURES_NAME = "figures.jsonl"
WINDOW = 10
THRESHOLD_PERCENT = 20

POOL_LINE = re.compile(r"RECORDED pool lock wait:((?: \w+=\d+)+)")
POOL_FIELD = re.compile(r"(\w+)=(\d+)")
ALLOC_LINE = re.compile(
    r"PASS compile-alloc-budget: (\w+) main\.o compile allocated ([\d,]+) words")
BOOT_LINE = re.compile(r"PASS kernel/(\w+) dmesg: .*?\bboot=([\d.]+) s")
COST_LINE = re.compile(r"RECORDED pool lock wait cost: pairs=\d+ plain=(\d+) ")
TCP_LINE = re.compile(r"PASS kernel-tcp-throughput: .*?(\d+)-(\d+) KiB/s")


def read_text(path):
    try:
        return pathlib.Path(path).read_bytes().decode("ascii", "replace")
    except OSError:
        return ""


def pool_figures(uart_text):
    """Per pool, and their sum, from the RPi5 lane's UART log."""
    found = POOL_LINE.findall(uart_text)
    if not found:
        return {"pool_lock_wait_sum": None}
    pools = {f"pool_{name}": int(count)
             for name, count in POOL_FIELD.findall(found[-1])}
    pools["pool_lock_wait_sum"] = sum(pools.values())
    cost = COST_LINE.findall(uart_text)
    pools["lock_pair_ticks"] = int(cost[-1]) if cost else None
    return pools


def log_figures(log_text):
    """Figures a green allcheck log prints. The first line per target is the
    one kept where a lane prints several, so the choice cannot drift."""
    figures = {"alloc_words_qemu": None, "alloc_words_rpi5": None,
               "boot_s_qemu": None, "boot_s_rpi5": None, "tcp_kib_s_low": None}
    for target, words in ALLOC_LINE.findall(log_text):
        key = f"alloc_words_{target}"
        if figures.get(key) is None:
            figures[key] = int(words.replace(",", ""))
    for target, seconds in BOOT_LINE.findall(log_text):
        key = f"boot_s_{target}"
        if figures.get(key) is None:
            figures[key] = float(seconds)
    tcp = TCP_LINE.search(log_text)
    if tcp:
        figures["tcp_kib_s_low"] = int(tcp.group(1))
    return figures


def lane_seconds(directory):
    """The sum of the lanes' elapsed seconds, or None with no receipt."""
    total = 0.0
    seen = False
    for path in sorted(pathlib.Path(directory).glob("*.jsonl")):
        for line in read_text(path).splitlines():
            try:
                total += float(json.loads(line)["elapsed"])
                seen = True
            except (ValueError, KeyError, TypeError):
                continue
    return round(total, 1) if seen else None


def elf_sizes(path):
    """(text, bss) in bytes of a little-endian ELF64: allocated executable
    sections, and allocated sections that occupy no file space."""
    try:
        data = pathlib.Path(path).read_bytes()
        if data[:6] != b"\x7fELF\x02\x01":
            return None, None
        shoff = struct.unpack_from("<Q", data, 0x28)[0]
        entsize, count = struct.unpack_from("<HH", data, 0x3a)
        text = bss = 0
        for index in range(count):
            at = shoff + index * entsize
            kind = struct.unpack_from("<I", data, at + 4)[0]
            flags = struct.unpack_from("<Q", data, at + 8)[0]
            size = struct.unpack_from("<Q", data, at + 32)[0]
            if flags & 2 and flags & 4:
                text += size
            elif flags & 2 and kind == 8:
                bss += size
        return text, bss
    except (OSError, struct.error):
        return None, None


def collect(commit, log_text, uart_text, timing_dir, build_root):
    row = {"commit": commit, "time": int(time.time())}
    row.update(pool_figures(uart_text))
    row.update(log_figures(log_text))
    row["lane_seconds_total"] = lane_seconds(timing_dir)
    for target in ("qemu", "rpi5"):
        text, bss = elf_sizes(pathlib.Path(build_root) / target / "kernel.elf")
        row[f"text_{target}"] = text
        row[f"bss_{target}"] = bss
        if row.get(f"alloc_words_{target}") is None:
            # Only the QEMU build prints its count; both leave the fact.
            count = read_text(pathlib.Path(build_root) / target /
                              "main.o.facts/allocwords").split()
            if count and count[0].isdigit():
                row[f"alloc_words_{target}"] = int(count[0])
    return row


def figures_path():
    common = subprocess.run(["git", "rev-parse", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return pathlib.Path(common).resolve() / "takibi-land" / FIGURES_NAME


def read_rows(path):
    rows = []
    for line in read_text(path).splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def moved(rows, window=WINDOW, threshold=THRESHOLD_PERCENT):
    """One line per figure that moved. A figure is compared only with values
    in at least half of each window: one blank does not hide a move, and one
    lone value does not make one."""
    if len(rows) < 2 * window:
        return []
    recent, previous = rows[-window:], rows[-2 * window:-window]
    names = sorted({name for row in recent + previous for name, value in row.items()
                    if isinstance(value, (int, float)) and name != "time"})
    lines = []
    for name in names:
        new = [r[name] for r in recent if isinstance(r.get(name), (int, float))]
        old = [r[name] for r in previous if isinstance(r.get(name), (int, float))]
        if len(new) * 2 < window or len(old) * 2 < window:
            continue
        before, after = statistics.median(old), statistics.median(new)
        if before == 0:
            continue
        percent = (after - before) * 100 / before
        if abs(percent) >= threshold:
            lines.append(f"{name}: median {before:g} -> {after:g} ({percent:+.0f}%) "
                         f"over the last {window} lands against the {window} before")
    return lines


def record(commit, log_path):
    row = collect(commit, read_text(log_path),
                  read_text("_build/kernel-hwtest-rpi5/uart.log"),
                  "_build/lane-timing", "kernel/build")
    path = figures_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="ascii") as out:
        out.write(json.dumps(row, sort_keys=True) + "\n")
    blank = sorted(name for name, value in row.items() if value is None)
    print(f"land-figures: kept in {path}" +
          (f"; blank: {', '.join(blank)}" if blank else ""))


def main(argv):
    try:
        if len(argv) == 3 and argv[0] == "record":
            record(argv[1], argv[2])
        elif argv in ([], ["compare"]):
            for line in moved(read_rows(figures_path())):
                print(line)
        else:
            print("usage: land_figures.py record COMMIT ALLCHECK_LOG | compare")
    except Exception as error:  # A land never stops for its bookkeeping.
        print(f"land-figures: not kept: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
