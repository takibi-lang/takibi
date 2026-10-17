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

GitHub issue #641 adds two rules that keep the compiler's lock-order check
covering the retry's liveness (kernel/models/WorldStopRetry.tla, variant
holdlock): `world_stop_machine_begin` declares an `acquires_lock_<rank>_`
effect whose rank is below every other lock class's, so a caller holding any
ranked guard cannot begin a stop; and its unranked body,
`world_stop_machine_begin_holding_probe`, is called only from a function
whose name ends in `_probe`.
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


RANK = re.compile(r"\bacquires_lock_([0-9]+)_([A-Za-z_0-9]+)")
FN = re.compile(r"\bfn\s+(\w+)\s*\(")
UNRANKED = "world_stop_machine_begin_holding_probe"


def rank_problems(texts: dict) -> list:
    """The stop's rank is the lowest; its unranked body is probe-only."""
    problems = []
    stop_rank = None
    others = []
    for relative, text in texts.items():
        code = "\n".join(line.split("//", 1)[0] for line in text.splitlines())
        for match in RANK.finditer(code):
            if match.group(2) == "world_stop":
                stop_rank = int(match.group(1))
            else:
                others.append((int(match.group(1)), match.group(2)))
        starts = [(m.start(), m.group(1)) for m in FN.finditer(code)]
        for call in re.finditer(r"\b" + UNRANKED + r"\s*\(", code):
            enclosing = [name for at, name in starts if at < call.start()]
            caller = enclosing[-1] if enclosing else "<top level>"
            if caller == UNRANKED:
                continue
            if caller == "world_stop_machine_begin" or caller.endswith("_probe"):
                continue
            line = code.count("\n", 0, call.start()) + 1
            problems.append(
                f"{relative}:{line}: {caller} calls {UNRANKED}, which "
                "carries no lock rank; only a single-attempt *_probe may "
                "hold a guard across a stop (#641)")
    if stop_rank is None:
        problems.append("world_stop_machine_begin declares no "
                        "acquires_lock_<rank>_world_stop (#641)")
    else:
        for rank, name in others:
            if rank <= stop_rank:
                problems.append(
                    f"lock class {name} has rank {rank}, not above the world "
                    f"stop's {stop_rank}: a caller holding it could begin a "
                    "stop its peers cannot acknowledge (#641)")
    return problems


def rank_control() -> bool:
    good = {"a": "fn world_stop_machine_begin() !{acquires_lock_10_world_stop} "
                 "{ world_stop_machine_begin_holding_probe(1); }\n"
                 "fn p() !{acquires_lock_40_pool} {}\n"
                 "fn x_probe() { world_stop_machine_begin_holding_probe(1); }\n"}
    if rank_problems(good):
        return False
    bad_caller = {"a": good["a"] + "fn retry() { world_stop_machine_begin_holding_probe(1); }\n"}
    bad_rank = {"a": good["a"].replace("acquires_lock_40_pool", "acquires_lock_5_pool")}
    unranked = {"a": good["a"].replace("acquires_lock_10_world_stop", "unsafe")}
    return all(len(rank_problems(t)) == 1 for t in (bad_caller, bad_rank, unranked))


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
    if not rank_control():
        print("FAIL world-stop-refusals: the #641 rank control was not "
              "refused (a non-probe caller, a lower rank, a missing rank)",
              file=sys.stderr)
        return 1
    total = 0
    files = 0
    problems = []
    texts = {}
    for path in sorted((REPO / "kernel").rglob("*.tkb")):
        text = path.read_text()
        texts[str(path.relative_to(REPO))] = text
        if not any(name + "::" in text for name in
                   ("WorldStopResult", "MachineStopResult")):
            continue
        files += 1
        arms, found = problems_in(text, str(path.relative_to(REPO)))
        total += arms
        problems.extend(found)
    problems.extend(rank_problems(texts))
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
