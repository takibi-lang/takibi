#!/usr/bin/env python3
"""A refused world stop is waited out or handed back, never a fail-stop.

GitHub issue #632. `world_stop_begin` answers Busy when another core holds
the stop and Partial when a core did not acknowledge in time. Both are
ordinary under load: another core may be rolling the same ASID counter over.
Two activation paths (exec's, and a fork child's first return) answered
either one with kernel_syscall_fail_stop. #584's four-core churn run then
fail-stopped the whole kernel at the ASID counter's first wrap.

The rule: in every WorldStopResult or MachineStopResult Busy/Partial arm
under kernel/, no fail-stop call. The arm may retry, yield, report or return
an error; the fail-stop is reserved for a Complete stop that a terminal path
keeps (machine_stop_keep_forever).

Lexical: an arm is the text from its `=>` to the next stop-result constructor
or the end of the enclosing match. What it cannot see is a refusal turned into
another value and failed on elsewhere: #632's fork-child path returned
Invalid from kernel_process_activate_current_root, and its caller
fail-stopped. The fix there retries inside the function, so the Invalid arm
no longer carries a refusal. The file's own control plants the
pre-#632 shape and requires the check to refuse it.
"""

import pathlib
import re
import sys

from pass_line import report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
ARM = re.compile(r"(?:WorldStopResult|MachineStopResult)::(Busy|Partial)\b[^=]*=>")
NEXT_ARM = re.compile(r"(?:WorldStopResult|MachineStopResult)::\w+")
FAIL_STOP = re.compile(r"\b(?:\w*fail_stop|kernel_invariant_stop(?:_with_frame)?)\s*\(")


def arms_in(text: str):
    """Yield (kind, line number, arm text) for each refusal arm."""
    for match in ARM.finditer(text):
        start = match.end()
        following = NEXT_ARM.search(text, start)
        end = following.start() if following else len(text)
        # A match's last arm runs to the match's closing brace; bound it so
        # a function after the match is never read as part of the arm.
        end = min(end, start + 1200)
        yield (match.group(1), text.count("\n", 0, match.start()) + 1,
               text[start:end])


def problems_in(text: str, relative: str) -> tuple[int, list[str]]:
    problems = []
    arms = 0
    for kind, line, body in arms_in(text):
        arms += 1
        code = "\n".join(part.split("//", 1)[0] for part in body.splitlines())
        if FAIL_STOP.search(code):
            problems.append(
                f"{relative}:{line}: the world-stop {kind} arm "
                "fail-stops. A refused stop is ordinary under load -- another "
                "core may hold it -- so wait it out and retry, or hand the "
                "work back (#632)")
    return arms, problems


def control() -> bool:
    planted = """
    match world_stop_begin(&kernel_world_stop, cores, SPINS) {
        WorldStopResult::Busy => {
            kernel_syscall_fail_stop(sp);
        }
        WorldStopResult::Partial(partial) => {
            world_stop_partial_release(partial, &kernel_world_stop);
            kernel_syscall_fail_stop(sp);
        }
        WorldStopResult::Complete(stopped) => {
            world_stop_release(stopped, &kernel_world_stop);
        }
    }
"""
    for result in ("WorldStopResult", "MachineStopResult"):
        sample = planted.replace("WorldStopResult", result)
        arms, found = problems_in(sample, "control")
        if arms != 2 or len(found) != 2:
            return False
        safe = sample.replace("kernel_syscall_fail_stop(sp);", "return;")
        arms, found = problems_in(safe, "control")
        if arms != 2 or found:
            return False
    for stop in ("kernel_invariant_stop()", "kernel_invariant_stop_with_frame(frame)"):
        sample = planted.replace("kernel_syscall_fail_stop(sp)", stop)
        arms, found = problems_in(sample, "control")
        if arms != 2 or len(found) != 2:
            return False
    return True


def main() -> int:
    if not control():
        print("FAIL world-stop-refusals: the control plants the pre-#632 "
              "fail-stop on Busy and Partial and the check did not refuse it",
              file=sys.stderr)
        return 1
    total = 0
    files = 0
    problems = []
    for path in sorted((REPO / "kernel").rglob("*.tkb")):
        text = path.read_text()
        if not any(name + "::" in text for name in
                   ("WorldStopResult", "MachineStopResult")):
            continue
        files += 1
        arms, found = problems_in(text, str(path.relative_to(REPO)))
        total += arms
        problems.extend(found)
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"FAIL world-stop-refusals: {len(problems)} refused world stop(s) "
              "fail-stop the kernel", file=sys.stderr)
        return 1
    report_pass("world-stop-refusals",
                f"{total} Busy/Partial arm(s) in {files} file(s) wait, yield "
                "or report, and none fail-stops the kernel",
                counts=total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
