#!/usr/bin/env python3
"""Validate the raw BusyBox dmesg transcript without normalizing its time."""

import argparse
import re
from pathlib import Path


LINE = re.compile(rb"^\[(\d{6})\.(\d{6})\] (.*)$")
# The console's own account of what it spent waiting on the wire, emitted once
# at the end of the boot suite (GitHub issue #454).
CONSOLE_SPIN = re.compile(
    rb"console: tx spin ticks=(\d+) bytes=(\d+) spun=(\d+) tickfreq=(\d+)")


def fail(message: str) -> None:
    raise SystemExit(f"FAIL kernel/dmesg: {message}")


CPU_PREFIX = re.compile(rb"^cpu([0-9]) ")
# GitHub issues #281/#208: the block layer's boot total. Held here for the
# same reason the console spin figure is -- it is a per-boot number, so no
# view can compare it, and a counter with no reader is the shape issue #410
# was filed about.
# GitHub issue #208: reads= counts what reached a device, and cache_hits= is
# what the block cache answered instead. Both are required, for the same
# reason the total is: a field this is the only reader of, dropped from the
# kernel's line, would retire the measurement with every lane green.
BLOCK_IO = re.compile(
    rb"block io: reads=(\d+) writes=(\d+) block_bytes=(\d+) "
    rb"cache_hits=(\d+) runs=(\d+) run_hits=(\d+)")

# GitHub issue #544: how often a userspace write to the UART waited for room
# in the transmit queue instead of spinning in the kernel, and how many of
# those waits slept. Required on both platforms, and the waits are required
# to be non-zero on the board, whose 115200-baud wire
# is slow enough that the shell's `cat /large.txt` must have waited. QEMU's
# PL011 drains as fast as it is written, so zero is a legitimate answer there.
UART_TX = re.compile(
    rb"uart tx: queue=(\d+) low_water=(\d+) writers_waited=(\d+) "
    rb"writers_slept=(\d+)")

# GitHub issue #541: the interactive ash session, on the host's clock. The
# UART driver writes every line it receives with the seconds since it
# connected, so the session's two edges are there even though the kernel's
# retained ring has overwritten its own record of the first by the time the
# final dmesg replays it, and never held the second (an `echo` in init.sh).
TIMED = re.compile(rb"^\s*(\d+\.\d+)\s(.*)$")
SESSION_START = b"interactive shell: uart blocked"
SESSION_END = b"busybox interactive shell exit: 0"


def ash_session_us(timing_log: Path) -> int:
    start = None
    end = None
    for line in timing_log.read_bytes().replace(b"\r", b"").splitlines():
        match = TIMED.match(line)
        if not match:
            continue
        text = match.group(2).strip()
        while text.startswith(b"/ # "):
            text = text[4:]
        seconds = float(match.group(1))
        if start is None and text == SESSION_START:
            start = seconds
        elif start is not None and end is None and text == SESSION_END:
            end = seconds
    if start is None or end is None or end < start:
        fail("the interactive ash session's edges -- `interactive shell: "
             "uart blocked` and then `busybox interactive shell exit: 0` -- "
             "were not both found in the host timing log, so the boot "
             "figure cannot be separated from the ash script's length. "
             "Refused rather than left unsubtracted: the bound below was "
             "calibrated on the separated figure")
    return round((end - start) * 1_000_000)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("uart_log", type=Path)
    parser.add_argument("--platform", choices=("qemu", "rpi5"), default="qemu")
    parser.add_argument("--timing-profile", choices=("local", "hosted"),
                        default="local")
    # The UART driver's per-line host timestamps. Required rather than
    # optional: without it the ash session would silently count as boot time
    # again, against a bound calibrated without it.
    parser.add_argument("--timing-log", type=Path, required=True)
    args = parser.parse_args()
    if args.platform != "qemu" and args.timing_profile != "local":
        parser.error("the hosted timing profile is only valid for QEMU")
    data = args.uart_log.read_bytes().replace(b"\r", b"")
    records: list[tuple[int, bytes]] = []
    for line in data.splitlines():
        match = LINE.match(line)
        if match:
            timestamp = int(match.group(1)) * 1_000_000 + int(match.group(2))
            records.append((timestamp, match.group(3)))
    if not records:
        fail("BusyBox dmesg emitted no timestamped records")
    # GitHub issue #465: monotonic PER CPU, and the qualifier is the whole
    # ordering rule rather than a relaxation to make a test pass.
    #
    # The ring's order is arrival at core 0, because core 0 is its only
    # writer -- that is what makes a separate sequence number unnecessary. A
    # record's timestamp is when its OWN core emitted the line, which for a
    # peer is before core 0 drained it. So a peer record can and does carry a
    # tick earlier than the record printed before it, and requiring one global
    # ordering would be requiring the peer's timestamp to be a lie.
    #
    # What must still hold is that no core's own records go backwards. A
    # `cpuN ` prefix names the writer; its absence means core 0.
    latest: dict[bytes, int] = {}
    for timestamp, text in records:
        writer = b"0"
        cpu = CPU_PREFIX.match(text)
        if cpu:
            writer = cpu.group(1)
        if timestamp < latest.get(writer, 0):
            fail(f"record timestamps are not monotonic on cpu{writer.decode()}")
        latest[writer] = timestamp

    by_text = {text: timestamp for timestamp, text in records}
    first = b"takibi kernel: EL1"
    # The whole bounded suite has run by the time the foreground server is
    # listening: it is the LAST timestamped record on both platforms, so its
    # timestamp is the boot duration (GitHub issue #411).
    boot_done = b"foreground server: listener ready port=8080"
    #
    # The bounds below were measured rather than guessed, on 2026-09-06:
    #
    #   QEMU  12 runs, 16.8 - 18.2 s. Eight sequential on a quiet host and
    #         four while the rest of the QEMU fan-out ran beside them; the
    #         concurrent ones were not slower on that development host.
    #         This does not calibrate a different host's per-core speed.
    #   RPi5  4 runs, 19.3 - 20.0 s. Real hardware, no host contention.
    #
    # Both distributions are within +-4% of their mean, which is why the
    # bounds can be this close: 25 s is 37% above the worst QEMU run ever
    # seen here and 28 s is 40% above the worst RPi5 one.
    #
    # The issue that asked for this suggested a 2x margin. 2x does not work:
    # the regression it was opened about was +10.7 s (13.0 -> 23.7 s), and
    # 2x of today's 17.4 s baseline is 34.8 s, which such a regression would
    # pass straight through. The bound is set to catch that class -- anything
    # over about +7 s -- and the headroom comes from the measured spread
    # being tiny, not from a multiplier.
    #
    # WHEN THIS FIRES, INVESTIGATE; DO NOT RAISE IT. What it guards against
    # is complexity added to a path that runs per page or per record: the
    # kernel still boots and still passes every view, it is just slower, and
    # nothing else in the suite says so. Raising the bound converts the one
    # signal back into silence. If a genuinely slower boot is intended, say
    # so here with the measurement that justifies it.
    #
    # The number is printed on every run, passing or not, because the bound
    # only catches the large regressions: a +3 s one stays green and is
    # visible only as a difference between two runs' output.
    # Recalibrated 2026-09-11, GitHub issue #541: the bound no longer
    # counts the interactive ash session. That session runs before the
    # milestone, so every command added to kernel/tests/common/ash/ash.stdin
    # was billed as boot time. One BusyBox exec costs 0.6-1.0 s under
    # cicheck's parallel load, and #538's first three commands took the
    # figure above to 25.2 s. At that point the only moves left were to stop
    # adding userspace tests, or to verify userspace-visible behaviour from
    # inside the kernel. Neither is what the bound is for.
    #
    # So the session's length, measured on the host's clock, is subtracted
    # and the bound applies to what is left. The two clocks run at the same
    # rate, which is all a subtraction of one length needs; they do not
    # share an origin (the RPi5 host log starts about 17 s before the guest,
    # at SWD load), which is why the length is subtracted rather than either
    # edge compared with a ring timestamp.
    #
    # Measured on the separated figure, 2026-09-11:
    #
    #   QEMU  main 15.5 s, debug 15.0 s, both under cicheck's parallel load
    #         (whole boots of 23.9 and 23.3 s, ash sessions of 8.4 and 8.3 s).
    #   RPi5  18.0 s (a 20.2 s boot, a 2.2 s session: real cores run
    #         BusyBox's execs about four times faster).
    #
    # The margin keeps the rule the 2026-09-06 numbers set: catch anything
    # over about +7 s, and in particular the +10.7 s of #411. 22 s is 6.5 s
    # above QEMU's worst and 25 s is 7 s above the board's. The hosted
    # profile's 35 s is kept as it was and now applies to the smaller
    # figure, so it is looser than before rather than stricter: no CI
    # session length has been measured yet. This validator prints all three
    # numbers on every run, and CI's own are what to recalibrate it from.
    assembled_prefix = b"memory: source=dtb base_bytes="
    if args.platform == "qemu":
        listener = b"virtio net: link ready mac=02:00:20:00:00:02"
        resumed = b"virtio net: tcp handshake echo close reconnect ok"
        minimum_delay = 3_500_000
        maximum_delay = 5_500_000
        maximum_boot = 22_000_000
        if args.timing_profile == "hosted":
            # CI run 34160800357, same 8924f4a6 kernel as the local 17.5s
            # boot: main 22.621s, debug 25.869s, both completed every network
            # exchange. Link-to-echo was 4.12s in both, versus 4.11s locally;
            # the extra time was outside that protocol wait. The local 25s
            # calibration is not portable to the hosted runner. Keep it for
            # local checks; 35s gives this runner 9.1s over its observed debug
            # boot and still rejects a +10.7s recurrence of issue #411.
            # This is an initial hosted calibration, not a measured tail
            # distribution. Every run reports its profile and duration.
            maximum_boot = 35_000_000
    else:
        listener = b"rp1 gem: link ready mac=02:00:20:00:00:02"
        resumed = b"rp1 gem: tcp handshake echo close reconnect ok"
        minimum_delay = 5_000_000
        maximum_delay = 9_000_000
        # GitHub issue #545: this was 41 s for a day, after the board's root
        # moved to the USB stick (94f1c36) and every exec read BusyBox from
        # it one sector at a time (33.6 s outside a 38.8 s session). The
        # block layer's read-ahead brought the board back to 18.3 s outside
        # a 3.6 s session, the figure the 25 s above was calibrated on.
        maximum_boot = 25_000_000
    if first not in by_text:
        fail("first kernel marker is absent")
    assembled = [item for item in records if item[1].startswith(assembled_prefix)]
    if len(assembled) != 1 or b" detected_mib=" not in assembled[0][1]:
        fail("fragment-assembled memory line is not one complete record")
    if listener not in by_text or resumed not in by_text:
        fail("bounded network retransmission markers are absent")
    if boot_done not in by_text:
        fail("the boot-duration milestone is absent, so this check would "
             "have passed having bounded nothing. The same line is held by "
             "kernel/tests/common/views/boot_milestone.expected so its "
             "disappearance fails a view too; the reasoning is in this file.")
    boot_us = by_text[boot_done]
    session_us = ash_session_us(args.timing_log)
    bounded_us = boot_us - session_us
    if bounded_us > maximum_boot:
        fail(
            f"{args.platform} ({args.timing_profile}) reached its last boot milestone in "
            f"{bounded_us / 1_000_000:.1f} s outside the "
            f"{session_us / 1_000_000:.1f} s interactive ash session "
            f"({boot_us / 1_000_000:.1f} s in all), over the "
            f"{maximum_boot / 1_000_000:.0f} s bound. INVESTIGATE, do not "
            "raise the bound: the number this guards against is complexity "
            "added to a path that runs per page or per record, which does "
            "not announce itself any other way."
        )
    elapsed = by_text[resumed] - by_text[listener]
    if elapsed < minimum_delay or elapsed > maximum_delay:
        fail(
            f"{args.platform} network interval is {elapsed} us, expected "
            f"{minimum_delay / 1_000_000:.1f}-{maximum_delay / 1_000_000:.1f} s"
        )
    # GitHub issue #454: what the console costs its callers, printed beside
    # the boot duration it is a share of. Reported rather than bounded: this
    # is the number the issue was missing, and a bound on it would be a bound
    # on how much the kernel logs, which is not the thing under control.
    # Printed on every run for the reason the SWD and TCP figures are --
    # growth then shows in a diff between two runs rather than in a memory.
    # Absence is a failure, not "nothing to report". This validator is the
    # ONLY reader of that line: no view compares it, because it carries
    # per-boot numbers. So a kernel that stops printing it, or prints it in a
    # shape this pattern no longer matches, would silently retire issue
    # #454's whole measurement while every lane stayed green -- the defect
    # scripts/check_documented_counts.py exists for, one level up. Every
    # capture that gets this far reached `foreground server: listener ready`,
    # and the line is printed before that on both platforms.
    console = CONSOLE_SPIN.search(data)
    if not console:
        fail("the boot reached its last milestone without printing "
             "`console: tx spin ticks=... bytes=... spun=... tickfreq=...`. "
             "That is issue #454's measurement and this is its only reader, "
             "so a missing line means the kernel's shape changed, not that "
             "the console cost nothing")
    spin = ""
    if console:
        ticks, sent, spun, frequency = (
            int(console.group(index)) for index in (1, 2, 3, 4))
        if frequency > 0 and sent > 0:
            seconds = ticks / frequency
            per = f"{seconds / spun * 1e6:.1f} us each" if spun else "none spun"
            spin = (f", console tx spin={seconds * 1000:.0f} ms over {sent} "
                    f"bytes ({spun} spun, {per})")
    block = BLOCK_IO.search(data)
    if not block:
        fail("the boot reached its last milestone without printing "
             "`block io: reads=... writes=... block_bytes=... cache_hits=... "
             "runs=... run_hits=...`. "
             "That is the "
             "measurement issues #281 and #208 are ordered against and this "
             "is its only reader, so a missing line means the kernel's shape "
             "changed rather than that the boot read no blocks")
    reads, writes, block_bytes, hits, runs, run_hits = (
        int(block.group(i)) for i in (1, 2, 3, 4, 5, 6))
    if reads == 0 or block_bytes == 0:
        fail(f"the boot reports {reads} block reads of {block_bytes} bytes, "
             "which cannot be right for a boot that mounts a filesystem and "
             "runs BusyBox from it -- the counter is not being reached")
    uart_tx = UART_TX.search(data)
    if not uart_tx:
        fail("the boot reached its last milestone without printing "
             "`uart tx: queue=... low_water=... writers_waited=... "
             "writers_slept=...`. That is "
             "issue #544's evidence that a UART write sleeps rather than "
             "spins, and this is its only reader")
    tx_queue, tx_low, tx_waited, tx_slept = (
        int(uart_tx.group(i)) for i in (1, 2, 3, 4))
    # The waits, not the sleeps: a waiting writer sleeps only when another
    # process happens to be ready, and the same kernel slept once on one
    # board run and not at all on the next (2026-09-11).
    if args.platform == "rpi5" and tx_waited == 0:
        fail("no userspace write waited for room in the UART transmit queue. "
             "On the board the shell's `cat /large.txt` outruns a 115200-baud "
             "wire, so a zero means writes are spinning in the kernel again, "
             "or the command that exercised it has gone from the ash script")
    block_io = (f", block io={reads} reads/{writes} writes of {block_bytes} B "
                f"({reads * block_bytes // 1024} KiB read, {hits} cache hits, "
                f"{runs} read-ahead runs answering {run_hits})")

    print(
        f"PASS kernel/{args.platform} dmesg: {len(records)} monotonic records, "
        f"assembled lines, delay={elapsed} us, boot={boot_us / 1_000_000:.1f} s, "
        f"ash-session={session_us / 1_000_000:.1f} s, "
        f"bounded={bounded_us / 1_000_000:.1f} s"
        f"{spin}{block_io}, uart tx waits={tx_waited} sleeps={tx_slept} "
        f"(queue {tx_queue}, low water {tx_low}), "
        f"timing-profile={args.timing_profile}, "
        f"boot-bound={maximum_boot / 1_000_000:.0f} s"
    )


if __name__ == "__main__":
    main()
