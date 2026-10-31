#!/usr/bin/env python3
"""Controls for scripts/land_figures.py (GitHub issue #1287).

Planted log lines must yield their figures, missing ones must be blanks and
not errors, and the comparison must speak only about a figure that moved.
Runs in-process over planted text and a temporary directory.
"""

import contextlib
import io
import json
import pathlib
import sys
import tempfile

from pass_line import report_pass
import land_figures as f

LOG = """PASS compile-alloc-budget: qemu main.o compile allocated 581,505,593 words, 98% of its budget
PASS compile-alloc-budget: rpi5 main.o compile allocated 600,000,000 words, 98% of its budget
PASS kernel/qemu dmesg: 239 monotonic records, assembled lines, delay=1 us, boot=70.7 s, ash-session=35.7 s
PASS kernel/qemu dmesg: 239 monotonic records, assembled lines, delay=1 us, boot=62.2 s, ash-session=33.0 s
PASS kernel-tcp-throughput: 1 path(s), 1715-1800 KiB/s (1.76-1.76 MB/s)
PASS kernel/rpi5 dmesg: 251 monotonic records, assembled lines, delay=7 us, boot=38.3 s, ash-session=17.4 s
"""
UART = ("[1.0] RECORDED pool lock wait cost: pairs=4096 plain=1 counted=1 freq=1\n"
        "RECORDED pool lock wait: process=10 fd_block=5\r\n")


def rows(old, new, name="pool_lock_wait_sum"):
    return [{name: old, "time": 1}] * 10 + [{name: new, "time": 2}] * 10


def problems():
    out = []
    logged = f.log_figures(LOG)
    if logged != {"alloc_words_qemu": 581505593, "alloc_words_rpi5": 600000000,
                  "boot_s_qemu": 70.7, "boot_s_rpi5": 38.3, "tcp_kib_s_low": 1715}:
        out.append(f"log figures read wrongly: {logged}")
    if f.pool_figures(UART) != {"pool_process": 10, "pool_fd_block": 5,
                                "pool_lock_wait_sum": 15, "lock_pair_ticks": 1}:
        out.append(f"pool figures read wrongly: {f.pool_figures(UART)}")
    with tempfile.TemporaryDirectory() as name:
        root = pathlib.Path(name)
        empty = f.collect("c", "", "", root / "absent", root / "absent")
        filled = [k for k, v in empty.items() if v is not None and k not in ("commit", "time")]
        if filled:
            out.append(f"missing inputs are not blanks: {filled}")
        if f.lane_seconds(root) is not None:
            out.append("no receipt must be blank, not 0")
        (root / "a.jsonl").write_text('{"elapsed": 1.5}\nnot json\n{"elapsed": 2}\n')
        if f.lane_seconds(root) != 3.5:
            out.append("lane seconds do not sum the readable receipts")
        (root / "bad.elf").write_bytes(b"not an elf")
        if f.elf_sizes(root / "bad.elf") != (None, None):
            out.append("a malformed ELF must be blank")
        figures = root / "figures.jsonl"
        figures.write_text(json.dumps({"x": 1}) + "\ntorn{\n")
        if f.read_rows(figures) != [{"x": 1}]:
            out.append("a torn row must be skipped")
    if f.moved(rows(100, 119)):
        out.append("19% was reported")
    if not f.moved(rows(100, 120)) or not f.moved(rows(100, 80)):
        out.append("a 20% move either way was not reported")
    if f.moved(rows(100, 200)[1:]):
        out.append("too little history was reported")
    if f.moved(rows(1, 9, "time")):
        out.append("the timestamp was compared")
    blanks = [{"a": None}] * 10 + [{"a": 5}] * 10
    if f.moved(blanks):
        out.append("a window of blanks was compared")
    # The stub stands in for an unwritable store, and keeps this control from
    # appending to the real one.
    def unwritable():
        raise OSError("planted")
    f.figures_path = unwritable
    with contextlib.redirect_stdout(io.StringIO()):
        if f.main(["record"]) != 0 or f.main(["record", "c", "/nonexistent/log"]) != 0:
            out.append("a bad call or an unwritable store must not fail")
    return out


def main():
    found = problems()
    if found:
        for problem in found:
            print(f"FAIL land-figures-controls: {problem}", file=sys.stderr)
        return 1
    report_pass("land-figures-controls",
                "planted figures read, blanks kept, only a 20% move reported",
                moves=len(f.moved(rows(100, 120))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
