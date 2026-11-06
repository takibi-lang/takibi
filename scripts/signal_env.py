#!/usr/bin/env python3
"""GitHub issue #1392: say which signals a check run inherited ignored or blocked.

A land started under nohup ran every lane with SIGHUP ignored; the
wait_status host oracle then answered differently (#1388) and nothing in
the log showed why. allcheck, cicheck and each begin-stamped lane print one
line here at start when they inherited an ignored or blocked signal
(this process reads its own masks), and stay silent otherwise:

    NOTE  signal environment (allcheck): ignored HUP; blocked none

This process's own masks are read: exec keeps ignored and blocked
signals, so they are what the lane's shell passed on. Python itself
ignores PIPE and XFSZ at startup, so those two cannot be told from an
inherited ignore and are left out. The parent shell is not read: bash
blocks CHLD around its own waits, which would be reported every time.
`--controls` decodes planted /proc masks.
"""
import signal
import sys

from pass_line import report_pass


def names(mask: int) -> list[str]:
    out = []
    for bit in range(64):
        if mask >> bit & 1:
            num = bit + 1
            try:
                out.append(signal.Signals(num).name.removeprefix("SIG"))
            except ValueError:
                out.append(str(num))
    return out


def masks(status_text: str) -> tuple[int, int]:
    ign = blk = 0
    for line in status_text.splitlines():
        key, _, value = line.partition(":")
        if key == "SigIgn":
            ign = int(value.strip(), 16)
        elif key == "SigBlk":
            blk = int(value.strip(), 16)
    return ign, blk


PYTHON_OWN_IGNORES = (1 << (signal.SIGPIPE - 1)) | (1 << (signal.SIGXFSZ - 1))


def line(label: str, status_text: str) -> str:
    ign, blk = masks(status_text)
    ign &= ~PYTHON_OWN_IGNORES
    if not ign and not blk:
        return ""
    return (f"NOTE  signal environment ({label}): ignored "
            f"{' '.join(names(ign)) or 'none'}; blocked {' '.join(names(blk)) or 'none'}")


def controls() -> int:
    cases = [
        ("SigBlk:\t0000000000000000\nSigIgn:\t0000000000000000\n", ""),
        ("SigBlk:\t0000000000000000\nSigIgn:\t0000000000000001\n",
         "NOTE  signal environment (x): ignored HUP; blocked none"),
        ("SigBlk:\t0000000000000000\nSigIgn:\t0000000001001000\n", ""),
        ("SigBlk:\t0000000000010000\nSigIgn:\t0000000000004001\n",
         "NOTE  signal environment (x): ignored HUP TERM; blocked CHLD"),
    ]
    for text, want in cases:
        got = line("x", text)
        if got != want:
            print(f"FAIL  signal-env control: got {got!r}, want {want!r}")
            sys.exit(1)
    return len(cases)


def main(argv: list[str]) -> int:
    if argv == ["--controls"]:
        n = controls()
        report_pass("signal-env controls", f"{n} planted /proc masks decoded", cases=n)
        return 0
    if len(argv) != 1:
        print("usage: signal_env.py LABEL | --controls", file=sys.stderr)
        return 2
    try:
        with open("/proc/self/status") as handle:
            text = handle.read()
    except OSError:
        return 0
    out = line(argv[0], text)
    if out:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
