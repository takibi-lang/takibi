#!/usr/bin/env python3
"""Refuse platform-independent code living in a per-platform file.

GitHub issue #470 was a formatter that was right on QEMU and wrong on RPi5
for months.  `uart_put_udec` was defined in BOTH
kernel/platform/qemu/uart.tkb and kernel/platform/rpi5/uart.tkb; QEMU's copy
carried ten decimal place values and RPi5's carried five, so on the board
every number of six digits or more printed as its low five.  54000000 came
out as `0`.  The boot logs then said the ARM generic timer was returning a
different value on every read, which cost two instrumented hardware boots
and an investigation into a timer that was working correctly.

Nothing in the language could have caught it.  The two platform trees are
never compiled together -- the Makefile builds the QEMU kernel from
kernel/platform/qemu/ and the RPi5 kernel from kernel/platform/rpi5/, in
separate compiler invocations -- so no type check, no `--forbid-trap` pass,
and no whole-program analysis ever sees both copies at once.  The
duplication is structurally invisible to the compiler, which is why this is
a build-time script instead.

What it looks for is the PRECONDITION, not the drift: a function defined in
both trees whose bodies are byte-identical today.  Identical copies are free
to stop being identical, and only one of them is read on any given boot.
The fix is to move the body somewhere both platforms read (see
kernel/printk/number.tkb, and uart_puts in kernel/printk/log.tkb) and leave
behind only what genuinely differs -- `uart_putc` IS the device and stays.

Not every identical pair is a defect.  An empty HAL slot that both platforms
happen to leave empty is legitimately per-platform: a platform is entitled
to fill it later.  Those, and duplications with an issue already tracking
them, are listed in ALLOWED below with the reason, so that the entry is a
claim a reviewer can disagree with, where silence was not.
"""

import pathlib
import re
import sys

PLATFORM_ROOT = pathlib.Path("kernel/platform")

# name -> why this identical pair is not a finding.  Adding a name here is a
# claim; removing the duplication is better.
ALLOWED = {
    "platform_shutdown":
        "empty HAL slot -- a platform may need to do something here",
    "uart_rx_discard":
        "empty HAL slot -- a platform whose RX needs draining fills it",
    "uart_tx_isr":
        "empty HAL slot -- a platform with a TX interrupt fills it",
    "platform_memory_detect":
        "GitHub issue #472 is actively rewriting both copies from the DTB",
}

FN_RE = re.compile(r"^(?:private )?fn ([A-Za-z0-9_]+)\s*\(")


def functions(path):
    """name -> body text, for every top-level fn in one file."""
    lines = path.read_text().split("\n")
    out = {}
    i = 0
    while i < len(lines):
        match = FN_RE.match(lines[i])
        if not match:
            i += 1
            continue
        body = []
        depth = 0
        opened = False
        while i < len(lines):
            body.append(lines[i])
            depth += lines[i].count("{") - lines[i].count("}")
            opened = opened or "{" in lines[i]
            i += 1
            if opened and depth <= 0:
                break
        out.setdefault(match.group(1), []).append("\n".join(body).strip())
    return out


def collect(platform):
    out = {}
    for path in sorted((PLATFORM_ROOT / platform).rglob("*.tkb")):
        for name, bodies in functions(path).items():
            for body in bodies:
                out.setdefault(name, []).append((path, body))
    return out


def main():
    platforms = sorted(p.name for p in PLATFORM_ROOT.iterdir() if p.is_dir())
    if len(platforms) < 2:
        print(f"PASS platform-parity: {len(platforms)} platform, nothing to compare")
        return 0

    trees = {name: collect(name) for name in platforms}
    findings = []
    allowed_hits = 0
    compared = 0

    first, rest = platforms[0], platforms[1:]
    for name, entries in sorted(trees[first].items()):
        others = [trees[other].get(name) for other in rest]
        if any(o is None for o in others):
            continue
        if len(entries) != 1 or any(len(o) != 1 for o in others):
            continue
        compared += 1
        path, body = entries[0]
        if any(o[0][1] != body for o in others):
            continue
        if name in ALLOWED:
            allowed_hits += 1
            continue
        where = ", ".join(
            str(p) for p, _ in [entries[0]] + [o[0] for o in others])
        findings.append((name, where, len(body.split("\n"))))

    if findings:
        print("FAIL platform-parity: platform-independent code in a "
              "platform file")
        for name, where, lines in findings:
            print(f"  {name}: {lines} identical lines in {where}")
        print("  These cannot drift apart today, and nothing would notice "
              "when they do --")
        print("  the platform trees are never compiled together (GitHub "
              "issue #470).")
        print("  Move the body where both platforms read it, or add it to "
              "ALLOWED in")
        print("  scripts/check_platform_file_parity.py with the reason.")
        return 1

    print(f"PASS platform-parity: {compared} functions defined in all of "
          f"{'/'.join(platforms)}, {allowed_hits} identical by declared "
          f"intent, 0 undeclared")
    return 0


if __name__ == "__main__":
    sys.exit(main())
