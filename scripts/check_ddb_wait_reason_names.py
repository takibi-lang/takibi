#!/usr/bin/env python3
"""DDB's wait view must name every state and reason the kernel can encode.

GitHub issue #529 replaced two opaque integer vocabularies with names, and
naming them created a second place they are written down. `ps` prints the raw
codes; `wait` prints `blocked`, `child-exit`, `net-rx`. The codes come from
kernel/kernel/process.tkb, which maps `ProcessSlotState` and
`ProcessWaitReason` onto integers for the debugger snapshot, and the names
come from kernel/arch/arm64/kernel/exception_evidence.tkb.

A reason added to the enum and not named here does not fail anything: the
view keeps working and prints `unknown` where a word should be, which is the
opacity the view exists to remove, reintroduced silently and only visible to
whoever is mid-stall at the time.

The name is DERIVED, not merely present: `UartRx` must be spelled `uart-rx`.
That is what makes this a check rather than a count -- a renamed enum case
with a stale word beside it fails, and so does a new case with no word.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROCESS = ROOT / "kernel" / "kernel" / "process.tkb"
DEBUGGER = ROOT / "kernel" / "arch" / "arm64" / "kernel" / "exception_evidence.tkb"

# (enum, the field process.tkb assigns, the namer that must cover it)
VOCABULARIES = (
    ("ProcessSlotState", "state", "ddb_state_name"),
    ("ProcessWaitReason", "wait_reason", "ddb_wait_reason_name"),
)


def kebab(case: str) -> str:
    """`UartRx` -> `uart-rx`, the spelling the view prints."""
    return re.sub(r"(?<!^)(?=[A-Z])", "-", case).lower()


def encoded(text: str, enum: str, field: str) -> dict[int, str]:
    """The integer each enum case is written into the DDB snapshot as."""
    pattern = (rf"{enum}::(\w+)\s*=>\s*\{{\s*output\[index\]\.{field}\s*="
               rf"\s*(\d+);\s*\}}")
    found = {}
    for case, code in re.findall(pattern, text):
        found[int(code)] = case
    return found


def named(text: str, function: str) -> dict[int, str]:
    """The word each integer is printed as."""
    body = re.search(rf"fn {function}\(.*?\)\s*->\s*\*u8\s*\{{(.*?)\n\}}",
                     text, re.DOTALL)
    if body is None:
        raise ValueError(f"{function} is missing or no longer returns *u8")
    return {int(code): word for code, word in
            re.findall(r"(\d+)\s*=>\s*\{\s*return\s+\"([a-z0-9-]+)\";\s*\}",
                       body.group(1))}


def main() -> int:
    process = PROCESS.read_text(encoding="ascii")
    debugger = DEBUGGER.read_text(encoding="ascii")
    problems = []
    checked = 0
    try:
        for enum, field, function in VOCABULARIES:
            codes = encoded(process, enum, field)
            if not codes:
                raise ValueError(
                    f"no {enum} -> {field} encoding found in "
                    f"kernel/kernel/process.tkb; this check reads the "
                    f"debugger snapshot's own copy and it has moved")
            words = named(debugger, function)
            for code, case in sorted(codes.items()):
                checked += 1
                want = kebab(case)
                if code not in words:
                    problems.append(
                        f"{enum}::{case} is written into the snapshot as "
                        f"{code} and {function} names no {code}: the wait "
                        f"view would print `unknown` for it")
                elif words[code] != want:
                    problems.append(
                        f"{enum}::{case} is {code}, and {function} calls "
                        f"{code} `{words[code]}` rather than `{want}`")
            for code, word in sorted(words.items()):
                if code not in codes:
                    problems.append(
                        f"{function} names {code} `{word}`, and no {enum} "
                        f"case is written into the snapshot as {code}: a "
                        f"word for a state that cannot occur")
    except ValueError as error:
        print(f"FAIL ddb-wait-reason-names: {error}")
        return 1

    if problems:
        for problem in problems:
            print(f"ERROR\tddb-wait-reason-names: {problem}")
        print(f"FAIL ddb-wait-reason-names: {len(problems)} name(s) do not "
              f"match the vocabulary the kernel encodes")
        return 1
    report_pass("ddb-wait-reason-names",
                f"{checked} process state and wait reason(s) are each named "
                f"by the DDB wait view, spelled from the enum case",
                checked=checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
