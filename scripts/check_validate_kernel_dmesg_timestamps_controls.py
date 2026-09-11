#!/usr/bin/env python3
"""Controls for the dmesg timestamp validator, which had none.

This validator asserts four things about a boot: that the records are
timestamped and monotonic, that a fragment-assembled line arrives whole, that
the bounded network interval falls in its window, and -- since GitHub issue
#411 -- that the boot reached its last milestone inside a measured bound.

Every one of those passes on every healthy boot, which is the shape that rots
unnoticed: a pattern that stops matching turns the check into a check of
nothing. So each is planted here and required to fail, with the diagnostic
checked rather than only the exit status.

The boot-duration case is the one the wording matters for. Its failure has to
say INVESTIGATE rather than describe a number, because the cheap response to a
slow boot is to raise the bound, and that converts the only signal there is
back into silence.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts" / "validate_kernel_dmesg_timestamps.py"

# A minimal healthy QEMU transcript: the markers the validator names, at
# timestamps inside every window it enforces.
HEALTHY = [
    (0.000030, "takibi kernel: EL1"),
    (0.000350, "kernel log: overwrite+line truncation reported"),
    (0.062737, "memory: source=dtb base_bytes=524288 detected_mib=1019 "
               "regions=1 reservations=2 allocator_pages=259696"),
    (3.100000, "virtio net: link ready mac=02:00:20:00:00:02"),
    (7.100000, "virtio net: tcp handshake echo close reconnect ok"),
    (17.400000, "foreground server: listener ready port=8080"),
]


def transcript(records) -> bytes:
    out = []
    for seconds, text in records:
        whole = int(seconds)
        micros = round((seconds - whole) * 1_000_000)
        out.append(f"[{whole:06d}.{micros:06d}] {text}".encode("ascii"))
    return b"\r\n".join(out) + b"\r\n"


# What a healthy boot prints for GitHub issue #454's console measurement. It
# is the DEFAULT rather than an addition because the validator now refuses a
# complete boot that lacks it: a case that says nothing about the console must
# still carry one, or it would be testing the console rule instead of its own.
HEALTHY_SPIN = (b"console: tx spin ticks=1000000 bytes=31919 spun=1077 "
                b"tickfreq=54000000\r\n")
# GitHub issues #281/#208: same reasoning one measurement over. A complete
# boot carries the block-layer total, so every case that is about something
# else has to carry one too or it would be testing this rule instead of its
# own.
HEALTHY_BLOCK_IO = (b"block io: reads=31000 writes=55 block_bytes=1024 "
                    b"cache_hits=93000 runs=400 run_hits=25000\r\n")
# GitHub issue #544: a board boot must show a writer that waited, so the
# default carries a non-zero count that serves both platforms.
HEALTHY_UART_TX = (b"uart tx: queue=512 low_water=256 writers_waited=5 "
                   b"writers_slept=3\r\n")
HEALTHY_TAIL = HEALTHY_SPIN + HEALTHY_BLOCK_IO + HEALTHY_UART_TX


# GitHub issue #541: the host timing log the UART driver writes, reduced to
# the interactive ash session's two edges. The end carries the prompt the
# driver sees in front of it, because the real one does. A 2 s session puts
# HEALTHY's 17.4 s boot at 15.4 s separated.
HEALTHY_SESSION = (11.0, 13.0)


def timing(session) -> bytes:
    if session is None:
        return b""
    start, end = session
    return (f"{start:8.3f}\tinteractive shell: uart blocked\n"
            f"{end:8.3f}\t/ # busybox interactive shell exit: 0\n"
            ).encode("ascii")


def run(records, platform="qemu", extra=None, profile="local",
        session=HEALTHY_SESSION):
    if extra is None:
        extra = HEALTHY_TAIL
    with tempfile.NamedTemporaryFile(suffix=".log") as log, \
            tempfile.NamedTemporaryFile(suffix=".timing") as timed:
        log.write(transcript(records) + extra)
        log.flush()
        timed.write(timing(session))
        timed.flush()
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), log.name, "--platform", platform,
             "--timing-profile", profile, "--timing-log", timed.name],
            capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def expect(label, records, ok, needle="", session=HEALTHY_SESSION):
    CASES.note()
    status, output = run(records, session=session)
    if (status == 0) != ok:
        print(f"FAIL dmesg-timestamps control: {label} exited {status}, "
              f"expected {'0' if ok else 'nonzero'}\n{output}")
        return False
    if needle and needle not in output:
        print(f"FAIL dmesg-timestamps control: {label} did not report "
              f"{needle!r}\n{output}")
        return False
    return True


def replace(records, text, seconds):
    return [(seconds if item[1] == text else item[0], item[1])
            for item in records]


def main() -> int:
    cases = [
        ("a healthy boot", HEALTHY, True,
         "boot=17.4 s, ash-session=2.0 s, bounded=15.4 s"),

        # Nothing to read at all. A summary of no records would read as a
        # boot with no problems.
        ("a transcript with no records", [], False, "emitted no timestamped"),

        # The milestone the bound is measured from. Without it the check
        # would pass having bounded nothing.
        ("a boot with no milestone",
         [r for r in HEALTHY if "foreground server" not in r[1]],
         False, "would have passed having bounded nothing"),

        # The regression this exists for: still boots, still passes every
        # view, just slower.
        ("a boot 11 seconds slower",
         replace(HEALTHY, "foreground server: listener ready port=8080", 28.4),
         False, "INVESTIGATE, do not raise"),

        # GitHub issue #541's acceptance: +7 s in the boot proper, outside
        # the ash session, still fails the recalibrated bound.
        ("a boot 7 seconds slower outside the ash session",
         replace(HEALTHY, "foreground server: listener ready port=8080", 24.4),
         False, "outside the 2.0 s interactive ash session"),

        # A boot just inside the bound stays green, so the bound is a bound
        # and not a coincidence.
        ("a boot just inside the bound",
         replace(HEALTHY, "foreground server: listener ready port=8080", 23.9),
         True, "bounded=21.9 s"),

        # The checks that were here before #411 and had no control either.
        ("a non-monotonic record",
         replace(HEALTHY, "virtio net: link ready mac=02:00:20:00:00:02", 0.000010),
         False, "not monotonic"),
        ("a network interval outside its window",
         replace(HEALTHY, "virtio net: tcp handshake echo close reconnect ok", 3.2),
         False, "network interval is"),
        ("a truncated fragment-assembled line",
         [(s, t.split(" detected_mib=")[0] if "detected_mib=" in t else t)
          for s, t in HEALTHY],
         False, "not one complete record"),
    ]

    for label, records, ok, needle in cases:
        if not expect(label, records, ok, needle):
            return 1

    # GitHub issue #541: what the separation is for. An ash script that grew
    # by eight seconds of execs moves the whole boot and not the bounded
    # figure; a boot that would have failed the old whole-boot bound passes.
    if not expect("a long ash session",
                  replace(HEALTHY,
                          "foreground server: listener ready port=8080", 30.0),
                  True, "ash-session=10.0 s, bounded=20.0 s",
                  session=(11.0, 21.0)):
        return 1
    # And a timing log that lacks the session is refused rather than read as
    # a session of zero, which would bill the whole script as boot again.
    if not expect("a timing log without the ash session", HEALTHY, False,
                  "were not both found in the host timing log",
                  session=None):
        return 1

    # With HEALTHY_SESSION's 2 s subtracted: 25.9, 34.9 and 35.1 s separated.
    for duration, ok in ((27.869018, True), (36.9, True), (37.1, False)):
        status, output = run(replace(
            HEALTHY, "foreground server: listener ready port=8080", duration),
            profile="hosted")
        needle = "boot-bound=35 s" if ok else "INVESTIGATE, do not raise"
        if (status == 0) != ok or needle not in output:
            print(f"FAIL dmesg-timestamps control: hosted {duration}s "
                  f"verdict is incorrect\n{output}")
            return 1
    status, output = run([], "rpi5", profile="hosted")
    if status == 0 or "only valid for QEMU" not in output:
        print("FAIL dmesg-timestamps control: hosted profile accepted for RPi5")
        return 1

    # The RPi5 bound is a different number, so it needs its own direction.
    # Its network window is 5-9 s rather than QEMU's 3.5-5.5, so the resumed
    # marker moves with the platform.
    rpi5 = [(10.1 if "reconnect ok" in t else s,
             t.replace("virtio net", "rp1 gem")) for s, t in HEALTHY]
    status, output = run(replace(
        rpi5, "foreground server: listener ready port=8080", 27.2), "rpi5")
    # GitHub issue #545: a bound failure also says where the time went.
    if (status == 0 or "INVESTIGATE, do not raise" not in output or
            "The largest gaps in the host timing log: " not in output or
            " s before " not in output):
        print("FAIL dmesg-timestamps control: an RPi5 boot 25.2 s outside "
              f"its ash session was accepted or reported oddly\n{output}")
        return 1
    status, output = run(replace(
        rpi5, "foreground server: listener ready port=8080", 26.9), "rpi5")
    if status != 0:
        print("FAIL dmesg-timestamps control: an RPi5 boot 24.9 s outside "
              f"its ash session was rejected by its 25 s bound\n{output}")
        return 1

    # GitHub issues #281/#208: the block-layer total is required, not merely
    # reported. A complete boot that omits it is a kernel whose shape changed.
    status, output = run(HEALTHY, "qemu", HEALTHY_SPIN)
    if status == 0 or "block io: reads=" not in output:
        print("FAIL dmesg-timestamps control: a complete boot without the "
              "block-layer total was accepted")
        return 1
    status, output = run(
        HEALTHY, "qemu",
        HEALTHY_SPIN
        + b"block io: reads=0 writes=0 block_bytes=1024 cache_hits=0 "
        b"runs=0 run_hits=0\r\n")
    if status == 0 or "cannot be right" not in output:
        print("FAIL dmesg-timestamps control: a boot claiming zero block "
              "reads was accepted")
        return 1

    # GitHub issue #544: the UART transmit line is required on both
    # platforms, and a board boot where no writer waited is refused. One
    # where writers waited and none slept passes: whether a waiting writer
    # sleeps depends on another process being ready at that moment.
    status, output = run(HEALTHY, "qemu", HEALTHY_SPIN + HEALTHY_BLOCK_IO)
    if status == 0 or "uart tx: queue=" not in output:
        print("FAIL dmesg-timestamps control: a boot without the uart tx "
              f"line was accepted\n{output}")
        return 1
    zero_waits = (HEALTHY_SPIN + HEALTHY_BLOCK_IO
                  + b"uart tx: queue=512 low_water=256 writers_waited=0 "
                  b"writers_slept=0\r\n")
    status, output = run(HEALTHY, "qemu", zero_waits)
    if status != 0 or "uart tx waits=0 sleeps=0" not in output:
        print("FAIL dmesg-timestamps control: QEMU was refused for a writer "
              f"that never had to wait\n{output}")
        return 1
    rpi5_ok = [(10.1 if "reconnect ok" in t else s,
                t.replace("virtio net", "rp1 gem")) for s, t in HEALTHY]
    status, output = run(rpi5_ok, "rpi5", zero_waits)
    if status == 0 or "writes are spinning in the kernel again" not in output:
        print("FAIL dmesg-timestamps control: a board boot where no UART "
              f"writer waited was accepted\n{output}")
        return 1
    waited_not_slept = (HEALTHY_SPIN + HEALTHY_BLOCK_IO
                        + b"uart tx: queue=512 low_water=256 writers_waited=4 "
                        b"writers_slept=0\r\n")
    status, output = run(rpi5_ok, "rpi5", waited_not_slept)
    if status != 0 or "uart tx waits=4 sleeps=0" not in output:
        print("FAIL dmesg-timestamps control: a board boot whose writers "
              f"waited without sleeping was refused\n{output}")
        return 1

    # GitHub issue #208: the cache's hit count is required too. The line in
    # the shape it had before the cache is a kernel that stopped reporting it.
    status, output = run(
        HEALTHY, "qemu",
        HEALTHY_SPIN + b"block io: reads=31000 writes=55 block_bytes=1024\r\n")
    if status == 0:
        print("FAIL dmesg-timestamps control: a block-layer total without "
              f"cache_hits was accepted\n{output}")
        return 1
    # GitHub issue #545: the read-ahead figures are required the same way.
    status, output = run(
        HEALTHY, "qemu",
        HEALTHY_SPIN + b"block io: reads=31000 writes=55 block_bytes=1024 "
        b"cache_hits=93000\r\n")
    if status == 0:
        print("FAIL dmesg-timestamps control: a block-layer total without "
              f"the read-ahead runs was accepted\n{output}")
        return 1
    status, output = run(HEALTHY, "qemu", HEALTHY_TAIL)
    if status != 0 or "93000 cache hits" not in output:
        print("FAIL dmesg-timestamps control: the cache hit count was not "
              f"reported from a capture that carries it\n{output}")
        return 1

    # GitHub issue #454: the console's spin measurement rides along with the
    # boot duration it is a share of. A number that is only printed when it
    # parses is a number that quietly disappears when the kernel line changes
    # shape, so the two directions are checked against each other.
    #
    # The untimestamped line is deliberate: the kernel emits it through the
    # same console it is measuring, outside the dmesg replay, which is why the
    # validator searches the whole capture rather than its parsed records.
    # Driven on the QEMU fixture because the parsing is platform-independent
    # and HEALTHY carries QEMU's network markers; the ticks are a real RPi5
    # sample, which is what makes the derived figures worth asserting.
    spin = b"console: tx spin ticks=136043016 bytes=31919 spun=31919 tickfreq=54000000\r\n"
    status, output = run(HEALTHY, "qemu", spin + HEALTHY_BLOCK_IO + HEALTHY_UART_TX)
    if status != 0 or "console tx spin=2519 ms" not in output:
        print("FAIL dmesg-timestamps control: the console spin measurement "
              f"was not reported from a capture that carries it\n{output}")
        return 1
    if "78.9 us each" not in output:
        print("FAIL dmesg-timestamps control: the per-byte cost, which is what "
              f"says the FIFO buys nothing, was not derived\n{output}")
        return 1
    # The line gone entirely. Nothing else reads it, so "no figure reported"
    # has to be a refusal rather than a quiet omission -- otherwise renaming a
    # field in the kernel retires the measurement and every lane stays green.
    status, output = run(HEALTHY, "qemu", b"")
    if status == 0:
        print("FAIL dmesg-timestamps control: a complete boot that never "
              f"printed the console measurement passed\n{output}")
        return 1
    if "issue #454" not in output:
        print("FAIL dmesg-timestamps control: the missing measurement was "
              f"refused without naming what went missing\n{output}")
        return 1
    # A field renamed out from under the pattern is the same failure arriving
    # by the likelier route, and must be refused the same way.
    status, output = run(
        HEALTHY, "qemu",
        HEALTHY_BLOCK_IO + b"console: tx spin ticks=1000000 bytes=31919 waited=1077 "
        b"tickfreq=54000000\r\n")
    if status == 0:
        print("FAIL dmesg-timestamps control: a renamed field silently "
              f"retired the measurement\n{output}")
        return 1
    status, output = run(
        HEALTHY, "qemu",
        HEALTHY_BLOCK_IO + HEALTHY_UART_TX
        + b"console: tx spin ticks=136043016 bytes=0 spun=0 tickfreq=54000000\r\n")
    if status != 0 or "console tx spin" in output:
        print("FAIL dmesg-timestamps control: zero bytes were divided by, or "
              f"reported as a measurement of something\n{output}")
        return 1

    report_pass(
        "dmesg-timestamps controls",
        "a healthy boot reports its duration, an empty transcript and a "
        "missing milestone are refused, a slow boot says INVESTIGATE on "
        "both platforms, a boot just inside each bound passes, a long ash "
        "session is not billed as boot and a timing log without one is "
        "refused, and the "
        "monotonic, interval and assembled-line checks each fail when "
        "broken, the block-layer total and its cache hit count are "
              "required and the total refused when it claims zero reads, and the console spin figure is derived, refused for "
        "zero bytes, and required rather than merely reported, the uart tx "
        "line is required and a board boot with no writer that waited is "
        "refused -- a "
        "complete boot that omits it, or renames a field out from under "
        "the pattern, is refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
