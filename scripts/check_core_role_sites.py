#!/usr/bin/env python3
"""A fixed core named in kernel code must say why that core is special.

WHY THIS EXISTS. The maintainer's rule (GitHub issue #775, DECISIONS.md):
every core's role should be as equal as possible, and wherever one core stays
special the reason is recorded. #497 found a secondary-only IRQ path that
assumed the tick was the only interrupt a secondary could take; #672 found
slot 0 (the boot process) special in a way nobody had written down, and the
first fix nearly disabled its stack guard. Both were asymmetries that existed
without a sentence saying why, so nobody re-asked the question when the
surrounding code changed.

THE RULE. A comparison of a core identity with a literal core number --
`cpu_id() == 0`, `cpu != 0`, `core == 1`, and the like -- in maintained kernel
`.tkb` code must have a comment containing `core-role:` on the same line or
within the few lines above it. The text after the marker is the reason, and
the inventory it belongs to is "Core roles" in kernel/CONCURRENCY.md. A whole
file may instead be declared below with a reason: EL0 fixture programs whose
scripted roles name cores on purpose, and boot fixtures whose choreography
pins a named core.

WHAT IT IS NOT. Lexical. It does not see a fixed core passed through a
constant (`SECONDARY_CORE_ID`), an array index, or an assembly file; the
inventory covers those by hand. It catches the common shape, at langcheck
cost, at the moment a new one is written.
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_only, code_skeleton

REPO = pathlib.Path(__file__).resolve().parent.parent
KERNEL = REPO / "kernel"
INVENTORY = REPO / "kernel" / "CONCURRENCY.md"
INVENTORY_HEADING = "## Core roles"

MARKER = "core-role:"
# How far above a site its marker may stand: one comment may cover the
# condition it introduces and its immediate continuation.
WINDOW = 8

IDENTITY = r"(?:cpu_id\s*\(\s*\)|cpu|core|raw_cpu|current_cpu)"
SITE = re.compile(
    rf"(?<![A-Za-z0-9_.]){IDENTITY}\s*(?:==|!=)\s*[0-9]+\b"
    rf"|\b[0-9]+\s*(?:==|!=)\s*{IDENTITY}(?![A-Za-z0-9_])")

# path -> why every site in that file may name a core without a marker.
FILE_REASONS = {
    "kernel/arch/arm64/kernel/peer_read.tkb":
        "EL0 fixture program: maps a CPU number to an affinity bit and waits "
        "for a peer CPU to be published",
    "kernel/arch/arm64/kernel/peer_settings.tkb":
        "EL0 fixture program: the parent stays on CPU 0 and the child is "
        "pinned to a secondary by design",
    "kernel/arch/arm64/kernel/exec_enomem_probe.tkb":
        "EL0 fixture program driven by GDB on CPU 0 and CPU 1",
    "kernel/kernel/workload_evidence.tkb":
        "boot workload fixture: its scripted phases pin named cores to "
        "measure migration and peer progress",
    "kernel/kernel/console_contention_evidence.tkb":
        "boot contention fixture: core 0 holds while a peer contends",
    "kernel/kernel/tcp_connection_contention_evidence.tkb":
        "boot contention fixture: a peer contends with core 0",
}


def sites(path: pathlib.Path):
    text = path.read_text(encoding="ascii")
    raw_lines = text.splitlines()
    code_lines = code_only(text).splitlines()
    # Sites are matched with string literals blanked too, so a log line that
    # says "cpu == 0" is not a site; the marker is read with them kept, so
    # one inside a string is not a reason.
    for index, code in enumerate(code_skeleton(text).splitlines()):
        if SITE.search(code):
            yield index + 1, (raw_lines, code_lines), index


def marked(lines, index) -> bool:
    """A marker in a comment: on the raw line, and blanked from the code."""
    raw_lines, code_lines = lines
    start = max(0, index - WINDOW)
    return any(MARKER in raw_lines[i] and MARKER not in code_lines[i]
               for i in range(start, index + 1))


def main() -> int:
    problems = []
    total = 0
    by_marker = 0
    by_file = 0
    files_used = set()
    for path in sorted(KERNEL.rglob("*.tkb")):
        relative = path.relative_to(REPO).as_posix()
        for number, lines, index in sites(path):
            total += 1
            if relative in FILE_REASONS:
                files_used.add(relative)
                by_file += 1
                continue
            if marked(lines, index):
                by_marker += 1
                continue
            problems.append(
                f"{relative}:{number}: `{lines[0][index].strip()}` names a "
                f"fixed core with no `{MARKER}` comment within {WINDOW} lines "
                f"above it. Make the behaviour the same on every core, or "
                f"write `// {MARKER} <why this core is special>` and add the "
                f"site to \"Core roles\" in kernel/CONCURRENCY.md "
                f"(GitHub issue #775)")

    for relative in FILE_REASONS:
        if relative not in files_used:
            problems.append(
                f"{relative}: declared in {pathlib.Path(__file__).name} as a "
                f"file whose sites need no marker, and it has no site (or no "
                f"longer exists). Remove the declaration")

    if INVENTORY_HEADING not in INVENTORY.read_text(encoding="utf-8"):
        problems.append(
            f"kernel/CONCURRENCY.md: no `{INVENTORY_HEADING}` section, which "
            f"every `{MARKER}` reason points to")

    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"FAIL core-role-sites: {len(problems)} fixed-core site(s) "
              "without a recorded reason", file=sys.stderr)
        return 1
    report_pass("core-role-sites",
                f"{total} fixed-core comparisons in kernel .tkb: {by_marker} "
                f"carry a core-role reason, {by_file} are in "
                f"{len(files_used)} declared fixture files, and none is "
                "special without saying why",
                counts=total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
