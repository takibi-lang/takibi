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

import difflib
import pathlib
import re
import sys

from pass_line import report_pass

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

# GitHub issue #517. The comparison above finds a FUNCTION defined identically
# in both trees. Duplication written inline -- inside main(), inside a match
# arm -- is not a function, and #470's failure mode does not care: two copies
# that are identical today are free to stop agreeing, and only one is read on
# any given boot. A 57-line probe sequence sat byte-identical in both platform
# init.tkb files until it was extracted by hand, and this check said PASS
# throughout.
#
# WHAT IS COUNTED, and why not raw lines. The longest identical run between
# the two init.tkb files that raw line counting finds is thirteen closing
# braces at decreasing indentation -- a structural artifact of deeply nested
# code that nobody can make drift. Meanwhile a nine-line run that declares the
# same variant twice is real. So a run is measured in SIGNIFICANT lines:
# not blank, not a comment, and carrying something besides punctuation.
#
# THE THRESHOLD IS A JUDGEMENT, and the measured distribution does not make it
# for us. Significant-line runs across the four file pairs today are
# 40 30 29 20 16 12 12 9 9 8 6 6 5 4 4 3..., with no gap wide enough to point
# at. Eight is chosen because everything at or above it in this tree is a
# block somebody could extract, and everything at or below six is the two
# platforms legitimately doing the same few things in the same order --
# `match ext2_mount(device)`, `if (fpsimd_irq_probe() == 0)`. A check that
# fires on those is one people learn to silence, which is the reasoning
# check_pipefail_early_exit.py already records for its own narrowness.
#
# WHAT IT MISSES, deliberately: the two six-line runs, which are a repeated
# `use` block with a variant declaration and a pair of identical halt arms.
# Both are real duplication and both are below the line.
MIN_SIGNIFICANT_RUN = 8

# (file name, first significant line) -> why this run is not a finding yet.
# Same contract as ALLOWED above: an entry is a claim a reviewer can disagree
# with. Unlike ALLOWED, every entry here is also a piece of work -- these are
# extractable, and the reason says so.
ALLOWED_RUNS = {
    ("intc.tkb", "fn platform_world_stop_notify(cores: usize, owner: usize) "
                 "!{unsafe} {"):
        "a function whose bodies genuinely diverge -- each GIC writes its own "
        "SGI register -- but whose target-list computation is written twice. "
        "The function comparison cannot see this one, which is the case "
        "GitHub issue #517 was filed about",
    ("intc.tkb", "timer_irq_handler();"):
        "the dispatch tail: timer, then the EL0/EL1 preemption branch that "
        "nine files assert against",
}


def significant(line):
    text = line.strip()
    if not text or text.startswith("//"):
        return False
    return re.sub(r"[{}();,]", "", text).strip() != ""


def allowed_function_spans(path):
    """Line ranges of functions already declared identical by intent.

    A run lying inside one of those is the same finding twice: the function
    comparison above has already reported it and a reviewer has already
    answered. Reporting it again would make the declaration look ineffective
    and would teach people to widen the exemption rather than read it.
    """
    lines = path.read_text().split("\n")
    spans = []
    index = 0
    while index < len(lines):
        match = FN_RE.match(lines[index])
        if not match or match.group(1) not in ALLOWED:
            index += 1
            continue
        start = index
        depth = 0
        opened = False
        while index < len(lines):
            depth += lines[index].count("{") - lines[index].count("}")
            opened = opened or "{" in lines[index]
            index += 1
            if opened and depth <= 0:
                break
        spans.append((start, index))
    return spans


def duplicated_runs(left, right):
    """Identical inline runs between two same-named platform files."""
    a = left.read_text().split("\n")
    b = right.read_text().split("\n")
    declared = allowed_function_spans(left)
    found = []
    for i, _, n in difflib.SequenceMatcher(None, a, b, autojunk=False
                                           ).get_matching_blocks():
        lines = [a[k] for k in range(i, i + n)]
        count = sum(1 for line in lines if significant(line))
        if count < MIN_SIGNIFICANT_RUN:
            continue
        # Containment is judged on the SIGNIFICANT lines: a run routinely
        # picks up a trailing blank or brace past the closing line of the
        # function it lies in, and that must not make a declared body report
        # itself again.
        body = [k for k in range(i, i + n) if significant(a[k])]
        if any(all(start <= k < end for k in body) for start, end in declared):
            continue
        opens = next(line.strip() for line in lines if significant(line))
        found.append((count, i + 1, opens))
    return found


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
        report_pass("platform-parity",
                    f"{len(platforms)} platform, nothing to compare",
                    platforms=len(platforms))
        return 0

    trees = {name: collect(name) for name in platforms}
    run_findings = []
    used_declarations = set()
    declared_runs = 0
    compared_pairs = 0
    first_tree = {p.name: p for p in (PLATFORM_ROOT / platforms[0]).rglob("*.tkb")}
    for other in platforms[1:]:
        other_tree = {p.name: p
                      for p in (PLATFORM_ROOT / other).rglob("*.tkb")}
        for name in sorted(set(first_tree) & set(other_tree)):
            compared_pairs += 1
            for count, line, opens in duplicated_runs(first_tree[name],
                                                      other_tree[name]):
                if (name, opens) in ALLOWED_RUNS:
                    declared_runs += 1
                    used_declarations.add((name, opens))
                    continue
                run_findings.append((name, line, count, opens))

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

    # A declaration that no longer matches anything is a claim about code that
    # has moved or gone. Left in place it reads as current, and the list stops
    # being the worklist it is meant to be -- the same reason pass_line refuses
    # a verdict that cannot tell "it holds" from "I never looked".
    stale = sorted(set(ALLOWED_RUNS) - used_declarations)
    if stale:
        print("FAIL platform-parity: ALLOWED_RUNS declares runs that no "
              "longer exist")
        for name, opens in stale:
            print(f"  {name}: nothing now opens with `{opens[:60]}`")
        print("  Remove the entry. The duplication it described is gone, and "
              "a declaration")
        print("  that outlives its subject makes the rest of the list look "
              "current when it")
        print("  is not.")
        return 1

    if run_findings:
        print("FAIL platform-parity: identical inline runs in per-platform "
              "files")
        for name, line, count, opens in run_findings:
            print(f"  {name}:{line}: {count} significant lines duplicated in "
                  f"every platform tree, opening `{opens[:56]}`")
        print("  A run this long is not two platforms doing the same few "
              "things; it is one")
        print("  body written twice, and only one copy is read on any given "
              "boot (GitHub")
        print("  issues #470, #517). Move it where both platforms read it -- "
              "the precedent is")
        print("  kernel/init/contention_probes.tkb -- or add it to "
              "ALLOWED_RUNS in")
        print("  scripts/check_platform_file_parity.py with the reason.")
        return 1

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

    report_pass("platform-parity",
                f"{compared} functions defined in all of "
                f"{'/'.join(platforms)}, {allowed_hits} identical by "
                f"declared intent, 0 undeclared; {compared_pairs} same-named "
                f"file pair(s) hold no undeclared inline run of "
                f"{MIN_SIGNIFICANT_RUN} significant lines "
                f"({declared_runs} declared)",
                compared_functions=compared)
    return 0


if __name__ == "__main__":
    sys.exit(main())
