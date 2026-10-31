#!/usr/bin/env python3
"""No lookup answers absence with a shared writable object (GitHub issue #1308).

WHY. Until #1289 a process lookup that found nothing returned a pointer to one
static ProcessRecord, which any core could then write. The same step that
removed it mapped the absent case of a root lookup to the boot root, which is
the same shape one level up: the kernel's real, shared address space answered
for a process that had gone (the #270 hazard). #1308 found that one by audit.

THE RULES.
1. A payload type of a RegionPool has no other statically allocated instance,
   except the rows of ALLOWED: storage for a sink has to come from somewhere,
   and a pool payload's only other home is a global.
2. A match arm for Absent, Stale or Missing does not name
   address_space_boot_root().

WHAT THIS MISSES. Both rules are lexical. A sink of a type that is not a pool
payload, or a boot root reached through a variable or another function, is not
seen. A failure there has to be found by review; the counters of
scripts/check_fallback_counters.py do not see it either, since nothing is
counted when a fallback answers quietly.
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_only

REPO = pathlib.Path(__file__).resolve().parent.parent
KERNEL = REPO / "kernel"

# (file, global): a static instance of a pool payload, and why it is no sink.
ALLOWED = {
    # Root 0's real backing: the MMU-off path needs it before the pool, and
    # only a root naming slot 0 reaches it.
    ("kernel/mm/address_space.tkb", "address_space_backing_root0"),
    # A two-core probe's own record, armed and read by that probe alone.
    ("kernel/kernel/signal_contention_evidence.tkb", "signal_probe_record"),
}

POOL = re.compile(r"\blet mut \w+\s*:\s*RegionPool\((\w+)\)")
STATIC = re.compile(r"^(?:private )?let mut (\w+)\s*:\s*\[?\s*(\w+)\b", re.MULTILINE)
ABSENT_ARM = re.compile(r"::(?:Absent|Stale|Missing)\s*=>\s*\{")


def arm_body(text: str, start: int) -> str:
    """The text of the brace block whose opening brace ends at `start`."""
    depth = 1
    at = start
    while at < len(text) and depth:
        if text[at] == "{":
            depth += 1
        elif text[at] == "}":
            depth -= 1
        at += 1
    return text[start:at]


def violations(sources: dict[str, str], allowed=frozenset(ALLOWED)) -> list[str]:
    """Every breach in `sources`, a map of repository path to blanked code."""
    payloads = set()
    for text in sources.values():
        payloads.update(POOL.findall(text))
    found = []
    for name, text in sorted(sources.items()):
        for match in STATIC.finditer(text):
            if match.group(2) in payloads and (name, match.group(1)) not in allowed:
                found.append(
                    f"{name}: `{match.group(1)}` is a static {match.group(2)}, a pool "
                    "payload: a lookup that falls back to it is a shared writable sink")
        for match in ABSENT_ARM.finditer(text):
            if "address_space_boot_root(" in arm_body(text, match.end()):
                found.append(
                    f"{name}: an absent-case arm answers the boot root: mint a root "
                    "with an empty backing handle, or answer a closed variant")
    return found


def load() -> dict[str, str]:
    sources = {}
    for path in sorted(KERNEL.rglob("*.tkb")):
        relative = path.relative_to(REPO).as_posix()
        if relative.startswith("kernel/tests/"):
            continue
        sources[relative] = code_only(path.read_text(encoding="ascii"))
    return sources


def main() -> int:
    sources = load()
    payloads = {p for text in sources.values() for p in POOL.findall(text)}
    problems = violations(sources)
    for problem in problems:
        print(f"FAIL no-record-sink: {problem}", file=sys.stderr)
    if problems:
        return 1
    report_pass(
        "no-record-sink",
        f"{len(sources)} files, {len(payloads)} pool payload types: no shared "
        "fallback object and no boot root for an absent lookup",
        files=len(sources), payloads=len(payloads))
    return 0


if __name__ == "__main__":
    sys.exit(main())
