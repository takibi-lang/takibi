#!/usr/bin/env python3
"""A tool that writes a lot must not feed a consumer that leaves early.

Under `set -o pipefail`, a pipeline's status is its rightmost failure. When
the consumer exits at the first match it closes the pipe, and a producer still
writing takes SIGPIPE -- so a pipeline that got its answer reports a failure,
and `set -e` aborts the script on it.

That is not hypothetical. `scripts/run_kernel_ddb_qemutest.sh` read one symbol
address with `llvm-nm-19 "$ELF" | awk '$3 == "sym" { print $1; exit }'`, and
LLVM's SIGPIPE handler exits `EX_IOERR`, which is 74. The symbol table is
123,783 bytes against a 64 KiB pipe buffer, so whether the producer had
finished writing when awk left came down to scheduling: this development host
won that race for months and a GitHub-hosted runner did not. It cost four CI
rounds to find, and the failure carried no output at all, because everything
before the script's first echo is silent setup (GitHub issue #521).

Deterministic once asked directly:

    set -o pipefail
    llvm-nm-19 kernel-debug.elf | head -1 >/dev/null ; echo $?   -> 74
    llvm-nm-19 kernel-debug.elf | cat  >/dev/null ; echo $?      ->  0

## What this refuses, and what it deliberately does not

Only a KNOWN LARGE producer feeding an early-exit consumer. The hazard is
general -- any producer can take SIGPIPE, and an ordinary one dies with 141,
which `pipefail` propagates just the same -- but measured on 2026-09-06 the
wide rule matches 27 sites across 13 files, none of which has ever been
observed to fail, mostly because their producers finish inside the pipe
buffer. A check that arrives with 27 findings to triage is a check people
learn to silence, and #521 records that the wide/narrow choice is a judgement
rather than an oversight.

So PRODUCERS below is a declared list, not a pattern guess: a tool goes in it
when its output is known to outgrow a pipe buffer here. Adding one is how this
check grows, and the growth is a review rather than a regex.

Exit code only (0 = pass, 1 = fail).
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Producers whose output is known to exceed a pipe buffer in this tree. The
# LLVM binutils emit whole symbol tables and disassembly; llvm-nm on the QEMU
# debug kernel alone is 123,783 bytes.
PRODUCERS = re.compile(r"\b(llvm-[a-z0-9]+-\d+|objdump|readelf)\b")

# Consumers that stop reading before EOF.
EARLY_EXIT = re.compile(
    r"\|\s*("
    r"awk\b[^|]*\bexit\b"          # awk program that calls exit
    r"|head\b"                     # head, with or without -n
    r"|sed\b[^|]*\bq\b"            # sed with a quit command
    r"|(sudo\s+)?grep\b[^|]*\s-[a-zA-Z]*[qm]"   # grep -q / grep -m N
    r")")

# (path, exact source line) -> why this one is safe. Empty on purpose: the
# tree has none today. An entry here is a claim a reviewer can disagree with,
# which is what the other check scripts use their own tables for.
DECLARED: dict[tuple[str, str], str] = {}


def tracked_shell_scripts() -> list[pathlib.Path]:
    listing = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z", "*.sh"],
        capture_output=True, check=True, timeout=60)
    return [ROOT / name for name in
            listing.stdout.decode("utf-8").split("\0") if name]


def findings(paths):
    """Yield (relative path, line number, line) for each hazardous pipeline."""
    for path in paths:
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if "pipefail" not in text:
            continue
        relative = str(path.relative_to(ROOT))
        for number, line in enumerate(text.splitlines(), 1):
            if not PRODUCERS.search(line) or not EARLY_EXIT.search(line):
                continue
            stripped = line.strip()
            if (relative, stripped) in DECLARED:
                continue
            yield relative, number, stripped


def main() -> int:
    scripts = tracked_shell_scripts()
    checked = [p for p in scripts
               if p.is_file() and "pipefail" in p.read_text(
                   encoding="utf-8", errors="replace")]
    problems = list(findings(scripts))

    for relative, number, line in problems:
        print(f"FAIL pipefail-early-exit: {relative}:{number} pipes a tool "
              "whose output can outgrow a pipe buffer into a consumer that "
              "leaves at the first match. Under pipefail the producer's "
              "SIGPIPE becomes the pipeline's status -- 74 for an LLVM tool "
              "-- and the script aborts having got its answer. Read to EOF "
              "instead: `$3 == \"s\" && !seen { print $1; seen = 1 }`.",
              file=sys.stderr)
        print(f"  {line}", file=sys.stderr)

    if problems:
        return 1

    report_pass(
        "pipefail-early-exit",
        f"{len(checked)} shell scripts set pipefail; none pipes a large "
        "producer into a consumer that leaves early",
        pipefail_scripts=len(checked))
    return 0


if __name__ == "__main__":
    sys.exit(main())
