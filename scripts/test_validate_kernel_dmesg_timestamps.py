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


def run(records, platform="qemu", extra=b"", profile="local"):
    with tempfile.NamedTemporaryFile(suffix=".log") as log:
        log.write(transcript(records) + extra)
        log.flush()
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), log.name, "--platform", platform,
             "--timing-profile", profile],
            capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def expect(label, records, ok, needle=""):
    status, output = run(records)
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
        ("a healthy boot", HEALTHY, True, "boot=17.4 s"),

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

        # A boot just inside the bound stays green, so the bound is a bound
        # and not a coincidence.
        ("a boot just inside the bound",
         replace(HEALTHY, "foreground server: listener ready port=8080", 24.9),
         True, "boot=24.9 s"),

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

    for duration, ok in ((25.869018, True), (34.9, True), (36.569018, False)):
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
        rpi5, "foreground server: listener ready port=8080", 30.0), "rpi5")
    if status == 0 or "INVESTIGATE, do not raise" not in output:
        print("FAIL dmesg-timestamps control: a 30s RPi5 boot was accepted "
              f"or reported oddly\n{output}")
        return 1
    status, output = run(replace(
        rpi5, "foreground server: listener ready port=8080", 27.9), "rpi5")
    if status != 0:
        print("FAIL dmesg-timestamps control: a 27.9s RPi5 boot was rejected "
              f"by its 28s bound\n{output}")
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
    spin = b"console: tx spin ticks=136043016 bytes=31919 tickfreq=54000000\r\n"
    status, output = run(HEALTHY, "qemu", spin)
    if status != 0 or "console tx spin=2519 ms" not in output:
        print("FAIL dmesg-timestamps control: the console spin measurement "
              f"was not reported from a capture that carries it\n{output}")
        return 1
    if "78.9 us/byte" not in output:
        print("FAIL dmesg-timestamps control: the per-byte cost, which is what "
              f"says the FIFO buys nothing, was not derived\n{output}")
        return 1
    status, output = run(HEALTHY, "qemu")
    if status != 0 or "console tx spin" in output:
        print("FAIL dmesg-timestamps control: a capture without the line "
              f"reported a spin figure anyway\n{output}")
        return 1
    status, output = run(
        HEALTHY, "qemu",
        b"console: tx spin ticks=136043016 bytes=0 tickfreq=54000000\r\n")
    if status != 0 or "console tx spin" in output:
        print("FAIL dmesg-timestamps control: zero bytes were divided by, or "
              f"reported as a measurement of something\n{output}")
        return 1

    print("PASS dmesg-timestamps controls: a healthy boot reports its "
          "duration, an empty transcript and a missing milestone are refused, "
          "a slow boot says INVESTIGATE on both platforms, a boot just inside "
          "each bound passes, and the monotonic, interval and assembled-line "
          "checks each fail when broken, and the console spin figure is "
          "derived when present, absent when not, and refused for zero bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
