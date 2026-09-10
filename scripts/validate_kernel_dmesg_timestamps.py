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
BLOCK_IO = re.compile(
    rb"block io: reads=(\d+) writes=(\d+) block_bytes=(\d+)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("uart_log", type=Path)
    parser.add_argument("--platform", choices=("qemu", "rpi5"), default="qemu")
    parser.add_argument("--timing-profile", choices=("local", "hosted"),
                        default="local")
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
    assembled_prefix = b"memory: source=dtb base_bytes="
    if args.platform == "qemu":
        listener = b"virtio net: link ready mac=02:00:20:00:00:02"
        resumed = b"virtio net: tcp handshake echo close reconnect ok"
        minimum_delay = 3_500_000
        maximum_delay = 5_500_000
        maximum_boot = 25_000_000
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
        maximum_boot = 28_000_000
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
    if boot_us > maximum_boot:
        fail(
            f"{args.platform} ({args.timing_profile}) reached its last boot milestone in "
            f"{boot_us / 1_000_000:.1f} s, over the {maximum_boot / 1_000_000:.0f} s "
            "bound. INVESTIGATE, do not raise the bound: the number this "
            "guards against is complexity added to a path that runs per page "
            "or per record, which does not announce itself any other way."
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
             "`block io: reads=... writes=... block_bytes=...`. That is the "
             "measurement issues #281 and #208 are ordered against and this "
             "is its only reader, so a missing line means the kernel's shape "
             "changed rather than that the boot read no blocks")
    reads, writes, block_bytes = (int(block.group(i)) for i in (1, 2, 3))
    if reads == 0 or block_bytes == 0:
        fail(f"the boot reports {reads} block reads of {block_bytes} bytes, "
             "which cannot be right for a boot that mounts a filesystem and "
             "runs BusyBox from it -- the counter is not being reached")
    block_io = (f", block io={reads} reads/{writes} writes of {block_bytes} B "
                f"({reads * block_bytes // 1024} KiB read)")

    print(
        f"PASS kernel/{args.platform} dmesg: {len(records)} monotonic records, "
        f"assembled lines, delay={elapsed} us, boot={boot_us / 1_000_000:.1f} s"
        f"{spin}{block_io}, timing-profile={args.timing_profile}, "
        f"boot-bound={maximum_boot / 1_000_000:.0f} s"
    )


if __name__ == "__main__":
    main()
