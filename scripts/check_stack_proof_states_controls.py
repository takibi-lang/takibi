#!/usr/bin/env python3
"""Negative controls for the stack-free proof check (GitHub issue #614).

The check passes on the tree, which is the shape that rots unnoticed. Each
way the proof could be loosened is planted in a copy of process.tkb and must
be refused for its own reason: start taking a Ready token again, reap taking
an Exited one, a token minted by a function that is not a named mint, a
token written as a literal, and a mint that no longer reads the stack owner.
"""

from pathlib import Path
import sys

import check_stack_proof_states as check
from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "kernel/kernel/process.tkb"
CASES = CaseCount()


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"control anchor occurs {text.count(old)} times: "
                           f"{old}")
    return text.replace(old, new, 1)


def case(name: str, text: str, wanted: str) -> list[str]:
    CASES.note()
    failures, _ = check.check(text)
    if not failures:
        return [f"{name}: planted defect passed"]
    if not any(wanted in failure for failure in failures):
        return [f"{name}: failure did not explain {wanted!r}: {failures}"]
    return []


def main() -> int:
    source = SOURCE.read_text(encoding="ascii")
    failures = []
    CASES.note()
    current, _ = check.check(source)
    if current:
        failures.append(f"current tree failed: {current}")

    failures += case(
        "start takes a Ready token again",
        replace_once(
            source,
            "        state: sink ScheduledProcessState[process, ProcessState::Startable])\n"
            "        -> ScheduledProcessState[process, ProcessState::Running] {",
            "        state: sink ScheduledProcessState[process, ProcessState::Ready])\n"
            "        -> ScheduledProcessState[process, ProcessState::Running] {"),
        "scheduled_process_start must take a ProcessState::Startable")
    failures += case(
        "reap takes an Exited token again",
        replace_once(
            source,
            "        state: sink ScheduledProcessState[process, ProcessState::Reapable])\n"
            "        !{unsafe, invalidates_ProcessHandle} {\n"
            "    scheduled_process_reap_teardown(owner);",
            "        state: sink ScheduledProcessState[process, ProcessState::Exited])\n"
            "        !{unsafe, invalidates_ProcessHandle} {\n"
            "    scheduled_process_reap_teardown(owner);"),
        "scheduled_process_reap must take a ProcessState::Reapable")
    failures += case(
        "a function that is not a mint builds a Startable token",
        source + "\nfn scheduled_process_forge(\n"
        "        owner: borrow ScheduledProcessOwner[process])\n"
        "        -> ScheduledProcessState[process, ProcessState::Startable] {\n"
        "    return scheduled_process_startable_state(owner);\n}\n",
        "scheduled_process_forge mints a stack-free token")
    failures += case(
        "a Reapable token written as a literal",
        source + "\nfn scheduled_process_forge_zombie(\n"
        "        owner: borrow ScheduledProcessOwner[process])\n"
        "        -> ScheduledProcessState[process, ProcessState::Reapable] {\n"
        "    let mut state: ScheduledProcessState[process, "
        "ProcessState::Reapable] =\n        { owner.pool_index };\n"
        "    return state;\n}\n",
        "writes a Reapable token as a literal")
    failures += case(
        "a start check that stopped reading the stack owner",
        replace_once(
            source,
            "    if (scheduled_process_record_at(owner.pool_index).stack_owner_cpu !=\n"
            "            PROCESS_STACK_UNOWNED) {\n"
            "        return ScheduledProcessStartCheck::Standing(state);",
            "    if (false) {\n"
            "        return ScheduledProcessStartCheck::Standing(state);"),
        "scheduled_process_start_check mints a token without reading "
        "stack_owner_cpu")

    if failures:
        for failure in failures:
            print(f"FAIL stack-proof-states controls: {failure}")
        return 1
    report_pass(
        "stack-proof-states controls",
        "the tree passes, and a start that takes Ready, a reap that takes "
        "Exited, a token minted outside the named functions, a token "
        "written as a literal and a check that no longer reads the stack "
        "owner are each refused for their own reason",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
