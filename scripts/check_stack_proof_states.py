#!/usr/bin/env python3
"""Keep the stack-free proof of a process start and a zombie reap in one place.

GitHub issue #614. StackOwnership.tla's StartsOnFreeStack says a process is
started, or reaped, only while no other core stands on its kernel stack. The
type checker enforces half of that: `scheduled_process_start` takes a
`ProcessState::Startable` token and `scheduled_process_reap` a
`ProcessState::Reapable` one, and a Ready or Exited token is rejected as a
static value mismatch. It cannot enforce the other half: the tokens are made
by a few functions in kernel/kernel/process.tkb, and it is those functions'
reading of `stack_owner_cpu` that makes the proof true. Nothing stops a later
edit from loosening a signature back to Ready, or from minting a token in a
new place without reading the owner. This check pins the shape:

- start takes only Startable, and reap and reap_remove only Reapable;
- the state constructors are called only from the named mint functions, and
  a token is never written as a literal anywhere else;
- every mint function reads `stack_owner_cpu`.

What a PASS says is that the trusted set is still the named one. It does not
say the read is right; the runtime check in start and exited_take, and the
protocol-trace replay's StartsOnFreeStack, are what watch that.
"""

from pathlib import Path
import re
import sys

from pass_line import report_pass

SOURCE = Path("kernel/kernel/process.tkb")

STARTABLE_MINTS = {"scheduled_process_ready_take",
                   "scheduled_process_start_check",
                   "scheduled_process_restart_check"}
REAPABLE_MINTS = {"scheduled_process_exited_take"}
CONSUMERS = {
    "scheduled_process_start": "Startable",
    "scheduled_process_reap": "Reapable",
    "scheduled_process_reap_remove": "Reapable",
}
CONSTRUCTORS = {"scheduled_process_startable_state": STARTABLE_MINTS,
                "scheduled_process_reapable_state": REAPABLE_MINTS}
LITERALS = {"Startable": "scheduled_process_startable_state",
            "Reapable": "scheduled_process_reapable_state"}

FUNCTION_RE = re.compile(r"^(?:private )?fn (\w+)\(", re.M)


def body_start(text: str, opener: int) -> int:
    """The `{` that opens a function's body, or -1.

    `opener` is the signature's `(`. The parameters are skipped by matching
    parentheses, since a refined parameter puts braces in them, and an effect
    row (`!{unsafe}`) is skipped after them, so an empty body `{}` is found
    like any other.
    """
    depth = 0
    position = opener
    while position < len(text):
        if text[position] == "(":
            depth += 1
        elif text[position] == ")":
            depth -= 1
            if depth == 0:
                break
        position += 1
    position += 1
    while position < len(text):
        if text[position] == "{":
            if text[position - 1] == "!":
                position = text.index("}", position)
            else:
                return position
        elif text[position] == ";":
            return -1
        position += 1
    return -1


def functions(text: str) -> dict[str, tuple[str, str]]:
    """name -> (signature, body) for every top-level function."""
    found = {}
    for match in FUNCTION_RE.finditer(text):
        brace = body_start(text, match.end() - 1)
        if brace < 0:
            continue
        depth = 0
        for offset in range(brace, len(text)):
            if text[offset] == "{":
                depth += 1
            elif text[offset] == "}":
                depth -= 1
                if depth == 0:
                    found[match.group(1)] = (text[match.start():brace],
                                             text[brace:offset + 1])
                    break
    return found


def check(text: str) -> tuple[list[str], int]:
    failures = []
    table = functions(text)
    for name, state in CONSUMERS.items():
        if name not in table:
            failures.append(f"{name} is missing")
            continue
        signature = " ".join(table[name][0].split())
        if f"ProcessState::{state}]" not in signature or \
                "ProcessState::Ready]" in signature or \
                "ProcessState::Exited]" in signature:
            failures.append(f"{name} must take a ProcessState::{state} "
                            "token and no other process state")
    for ctor, mints in CONSTRUCTORS.items():
        if ctor not in table:
            failures.append(f"{ctor} is missing")
        for name, (_, body) in table.items():
            if name != ctor and f"{ctor}(" in body and name not in mints:
                failures.append(f"{name} mints a stack-free token through "
                                f"{ctor}, and is not one of "
                                f"{', '.join(sorted(mints))}")
    for mint in sorted(STARTABLE_MINTS | REAPABLE_MINTS):
        if mint not in table:
            failures.append(f"{mint} is missing")
        elif "stack_owner_cpu" not in table[mint][1]:
            failures.append(f"{mint} mints a token without reading "
                            "stack_owner_cpu")
    for state, ctor in LITERALS.items():
        literal = f"ScheduledProcessState[process, ProcessState::{state}] ="
        for name, (_, body) in table.items():
            if literal in body and name != ctor:
                failures.append(f"{name} writes a {state} token as a "
                                f"literal instead of calling {ctor}")
    examined = len(table)
    return failures, examined


def main() -> int:
    failures, examined = check(SOURCE.read_text(encoding="utf-8"))
    for failure in failures:
        print(f"ERROR stack-proof-states: {failure}")
    if failures:
        print("FAIL stack-proof-states: the stack-free proof is no longer "
              "made in the named places")
        return 1
    report_pass(
        "stack-proof-states",
        f"start takes only Startable and reap only Reapable; "
        f"{len(STARTABLE_MINTS) + len(REAPABLE_MINTS)} mint functions read "
        f"stack_owner_cpu and nothing else builds the tokens "
        f"({examined} functions read)",
        functions=examined)
    return 0


if __name__ == "__main__":
    sys.exit(main())
