#!/usr/bin/env python3
"""DDB's process view must name the signals the kernel actually accepts.

GitHub issue #564: a napping process carrying a SIGTERM its parent had
already sent is indistinguishable from one that was never signalled, because
`kernel_process_current_termination_signal_take` refuses a SIGTERM the mask
blocks. `ps` now prints both words, and printing them created a second place
the signal vocabulary is written down.

The numbers live in kernel/kernel/syscall.tkb -- kill(2) accepts exactly
`LINUX_SIGTERM` and `LINUX_SIGCHLD` and rejects everything else with EINVAL --
while the words live in kernel/arch/arm64/kernel/exception_evidence.tkb. A
signal the kernel starts accepting and does not name there does not fail
anything: the view keeps working and prints a bare hex remainder where a word
should be, which is the opacity the rendering exists to remove, reintroduced
silently and only visible to whoever is mid-stall at the time.

The word is DERIVED, not merely present: `LINUX_SIGTERM` must be spelled
`sigterm`. That is what makes this a check rather than a count -- a renamed
constant with a stale word beside it fails, and so does a newly accepted
signal with no word.

The remainder is checked too. `ddb_put_signal_set` prints the named bits and
then whatever is left as hex, so the mask it subtracts must be exactly the
bits it named: a named bit missing from it is printed twice, and an unnamed
bit inside it is dropped from a view whose whole claim is that nothing is.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
SYSCALL = ROOT / "kernel" / "kernel" / "syscall.tkb"
DEBUGGER = ROOT / "kernel" / "arch" / "arm64" / "kernel" / "exception_evidence.tkb"

RENDERER = "ddb_put_signal_set"


def accepted(text: str) -> dict[str, int]:
    """The signals kill(2) lets through, and the numbers they stand for."""
    arm = re.search(r"if \(number == AARCH64_NR_KILL\) \{(.*?)\n    \}",
                    text, re.DOTALL)
    if arm is None:
        raise ValueError(
            "no kill(2) arm found in kernel/kernel/syscall.tkb; this check "
            "reads the guard that decides which signals exist and it has "
            "moved")
    guard = re.search(r"if \(x1 != 0(?:\s*&&\s*x1 != LINUX_\w+)+\) \{",
                      arm.group(1))
    if guard is None:
        raise ValueError(
            "kill(2) no longer rejects unaccepted signals with a "
            "`x1 != LINUX_...` guard; the accepted set cannot be derived")
    names = re.findall(r"LINUX_(\w+)", guard.group(0))
    numbers = {}
    for name in names:
        value = re.search(rf"const LINUX_{name}: usize = (\d+);", text)
        if value is None:
            raise ValueError(f"kill(2) accepts LINUX_{name} and no "
                             f"`const LINUX_{name}` gives it a number")
        numbers[name] = int(value.group(1))
    return numbers


def declared(text: str) -> dict[str, int]:
    """The signal numbers the debugger declares it has words for."""
    return {name: int(value) for name, value in
            re.findall(r"const DDB_SIGNAL_(\w+): usize = (\d+);", text)}


def renderer(text: str) -> tuple[dict[str, str], dict[str, str], list[str]]:
    """(binding -> constant suffix, binding -> printed word, remainder)."""
    body = re.search(rf"fn {RENDERER}\(set: usize\)[^{{]*\{{(.*?)\n\}}",
                     text, re.DOTALL)
    if body is None:
        raise ValueError(f"{RENDERER}(set: usize) is missing or reshaped")
    text = body.group(1)
    bits = dict(re.findall(r"let (\w+): usize = 1 << \(DDB_SIGNAL_(\w+) - 1\);",
                           text))
    words = dict(re.findall(
        r"\(set & (\w+)\) != 0\) \{.*?ddb_puts\(\"([a-z][a-z0-9-]*)\"\)",
        text, re.DOTALL))
    kept = re.search(r"let remainder: usize = set & ~\(([^)]*)\);", text)
    if kept is None:
        raise ValueError(
            f"{RENDERER} no longer subtracts the bits it named before "
            f"printing the remainder, so a named or an unnamed bit is lost")
    return bits, words, [term.strip() for term in kept.group(1).split("|")]


def main() -> int:
    try:
        numbers = accepted(SYSCALL.read_text(encoding="ascii"))
        debugger = DEBUGGER.read_text(encoding="ascii")
        constants = declared(debugger)
        bits, words, remainder = renderer(debugger)
    except (OSError, ValueError) as error:
        print(f"FAIL ddb-signal-names: {error}")
        return 1

    problems = []
    for name, number in sorted(numbers.items()):
        if name not in constants:
            problems.append(
                f"kill(2) accepts LINUX_{name} and the debugger declares no "
                f"DDB_SIGNAL_{name}: the process view would print it as a "
                f"bare hex remainder")
        elif constants[name] != number:
            problems.append(
                f"LINUX_{name} is {number} and DDB_SIGNAL_{name} is "
                f"{constants[name]}: the view would name the wrong bit")
    for name in sorted(set(constants) - set(numbers)):
        problems.append(
            f"DDB_SIGNAL_{name} names a signal kill(2) does not accept: a "
            f"word for a bit that cannot be set")

    for name in sorted(set(constants) & set(numbers)):
        want = name.lower()
        holders = [binding for binding, suffix in bits.items()
                   if suffix == name]
        if not holders:
            problems.append(
                f"DDB_SIGNAL_{name} is declared and {RENDERER} derives no "
                f"bit from it: a constant nothing tests")
            continue
        for binding in holders:
            if binding != want:
                problems.append(
                    f"DDB_SIGNAL_{name}'s bit is bound as `{binding}` rather "
                    f"than `{want}`")
            if binding not in words:
                problems.append(
                    f"{RENDERER} derives `{binding}` and never tests it "
                    f"against the set: a named signal that prints nothing")
            elif words[binding] != want:
                problems.append(
                    f"DDB_SIGNAL_{name} is printed as `{words[binding]}` "
                    f"rather than `{want}`")
            if binding not in remainder:
                problems.append(
                    f"`{binding}` is named and not subtracted from the "
                    f"remainder: the view would print that signal twice")

    for term in remainder:
        if term not in bits:
            problems.append(
                f"the remainder subtracts `{term}`, which {RENDERER} does "
                f"not derive from a DDB_SIGNAL constant: a bit hidden from a "
                f"view that claims to drop nothing")

    if problems:
        for problem in problems:
            print(f"ERROR\tddb-signal-names: {problem}")
        print(f"FAIL ddb-signal-names: {len(problems)} signal(s) are not "
              f"named as the kernel accepts them")
        return 1
    report_pass("ddb-signal-names",
                f"{len(numbers)} signal(s) kill(2) accepts are each named by "
                f"the DDB process view, spelled from the constant, and "
                f"subtracted from its hex remainder",
                signals=len(numbers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
