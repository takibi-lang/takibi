#!/usr/bin/env python3
"""A dead-slot fallback must be counted, and its count must be able to fail.

Several accessors in this kernel answer with a shared record when the handle
they were given names nothing live -- an image record, a target root, an
address-space backing, an fd record, a process record, a TCP connection or
frame. The fallback exists so that sixty-odd call sites need no error path
they could not act on, and the counter beside it is what keeps it from being
silent.

Two things went wrong with that, and this refuses both (GitHub issue #410).

**A counter with no reader.** `process_image_root_fallback_uses` had one for
months. Issue #270 then hit exactly the case it counted -- a teardown
resolving through root 0, unmapping PID 1 -- and nothing in the boot said so,
because nothing read the number. So: every accessor of this family must be
named by the one function that sums them.

**A report that cannot fail.** The per-counter reports print only when their
count is NONZERO, so a boot in which a fallback fired GAINED a line -- and a
line no filter captures is a line no expected file misses. Measured
2026-09-07, of the six counters only `process table:` and `fd table:` were
caught at all, and only because their prefixes collide with two lines the
process-lifecycle view already wanted; the `process image:`, `address space:`
and `tcp` prefixes are matched by no filter in the tree. So: the sum is
reported POSITIVELY, on the good path, and that line must appear in a view's
expected file -- the shape issues #401 and #406 already use, where a boot that
broke the invariant LOSES a line and the lane goes red.

WHAT THIS DOES NOT CATCH. The accessors are found by name, so a new counter
whose reader is called something other than `..._missing_uses` or
`..._fallback_uses` is invisible here. The naming convention is this check's
input rather than its conclusion. What makes that acceptable is the direction
of the failure: the six that exist all follow it, a seventh written by copying
one of them inherits it, and the alternative -- inferring "this return is a
fallback" from the shape of a match arm -- would report on prose rather than
on a rule anyone agreed to.
"""

import pathlib
import re
import sys

from pass_line import report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
KERNEL = REPO / "kernel"
VIEWS = KERNEL / "tests"

# The one function that sums them, and the report it gates.
GATE = "dead_slot_fallback_uses"

ACCESSOR = re.compile(r"^fn ([a-z0-9_]*(?:missing|fallback)_uses)\(", re.MULTILINE)
GATE_BODY = re.compile(
    r"fn " + GATE + r"\(\)[^{]*\{(.*?)\n\}", re.DOTALL)
CALL = re.compile(r"([a-z0-9_]+)\(\)")


def kernel_sources():
    return sorted(KERNEL.rglob("*.tkb"))


def gate_body(sources) -> tuple[str, pathlib.Path]:
    for path in sources:
        match = GATE_BODY.search(path.read_text(encoding="ascii"))
        if match:
            return match.group(1), path
    raise SystemExit(
        f"FAIL fallback-counters: no `fn {GATE}()` in kernel/. It is what "
        "makes every dead-slot fallback counter readable by something that "
        "can fail; without it this check has nothing to compare against.")


def positive_line(sources) -> str | None:
    """The line the gate prints when every counter is zero."""
    for path in sources:
        text = path.read_text(encoding="ascii")
        match = re.search(
            r"if \(" + GATE + r"\(\) == 0\) \{\s*"
            r'kernel_boot_log\("([^"]*)\\n"\);',
            text)
        if match:
            return match.group(1)
    return None


def main() -> int:
    sources = kernel_sources()
    problems = []

    accessors = {}
    for path in sources:
        for name in ACCESSOR.findall(path.read_text(encoding="ascii")):
            accessors[name] = path
    if not accessors:
        raise SystemExit(
            "FAIL fallback-counters: no dead-slot fallback accessor found in "
            f"{len(sources)} kernel files. Either they were all renamed out "
            "from under this check or it stopped looking; both are failures.")

    body, gate_path = gate_body(sources)
    summed = set(CALL.findall(body))
    for name, path in sorted(accessors.items()):
        if name not in summed:
            problems.append(
                f"{path.relative_to(REPO)}: {name}() is a dead-slot fallback "
                f"counter that {GATE}() does not sum, so a boot in which it "
                "fires fails nothing")
    for name in sorted(summed - set(accessors)):
        problems.append(
            f"{gate_path.relative_to(REPO)}: {GATE}() sums {name}(), which is "
            "not a dead-slot fallback counter; the sum has to be exactly this "
            "family or the positive line stops meaning what it says")

    line = positive_line(sources)
    if line is None:
        problems.append(
            f"{gate_path.relative_to(REPO)}: {GATE}() gates no positive "
            "report. A count printed only when it is nonzero adds an "
            "unmatched line, which no expected file misses")
    else:
        asserted = [path for path in sorted(VIEWS.rglob("*.expected"))
                    if line in path.read_text(encoding="ascii")]
        if not asserted:
            problems.append(
                f"no view expects {line!r}, so the boot prints it and nothing "
                "notices when it stops being printed -- which is the moment a "
                "fallback fired")

    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"FAIL fallback-counters: {len(problems)} dead-slot fallback "
              "report(s) cannot fail a lane", file=sys.stderr)
        return 1
    report_pass("fallback-counters",
                f"{len(accessors)} dead-slot fallback counter(s) are summed by "
                f"{GATE}(), whose positive line is expected by a view",
                counters=len(accessors))
    return 0


if __name__ == "__main__":
    sys.exit(main())
