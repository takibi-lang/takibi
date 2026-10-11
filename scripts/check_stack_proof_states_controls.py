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
        "reap_remove takes an Exited token again",
        replace_once(
            source,
            "        state: sink ScheduledProcessState[process, ProcessState::Reapable])\n",
            "        state: sink ScheduledProcessState[process, ProcessState::Exited])\n"),
        "scheduled_process_reap_remove must take a ProcessState::Reapable")
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
            "    if (scheduled_process_record_locked(guard, process_slot_word(owner.pool_index)).stack_owner_cpu !=\n"
            "            PROCESS_STACK_UNOWNED) {\n"
            "        return ScheduledProcessStartCheck::Standing(state);",
            "    if (false) {\n"
            "        return ScheduledProcessStartCheck::Standing(state);"),
        "scheduled_process_start_check mints a token without reading "
        "stack_owner_cpu")

    # GitHub issue #661: the frame handle's mint set and its bare-usize seams.
    def frames(name: str, text: str, wanted: str) -> list[str]:
        CASES.note()
        found, _ = check.check_frames({"control.tkb": text})
        if not found:
            return [f"{name}: planted defect passed"]
        if not any(wanted in failure for failure in found):
            return [f"{name}: failure did not explain {wanted!r}: {found}"]
        return []

    CASES.note()
    clean, _ = check.check_frames({
        "control.tkb": "fn kernel_syscall_migrate_return(frame_sp: usize) {\n"
                       "    let mut f: FrameRef = frame_ref_from_entry(frame_sp);\n"
                       "}\n"})
    if clean:
        failures.append(f"a declared entry was refused: {clean}")
    for declaration in (
        "let mut frame: FrameRef[p];",
        "let frame: FrameRef[p];",
        "let\n mut renamed : FrameRef [p] ;",
    ):
        failures += frames(
            "default frame initialization", "fn forge(p: usize @ p) { " +
            declaration + " }", "default FrameRef initialization")
    failures += frames(
        "global default frame initialization", "let mut frame: FrameRef[p];",
        "default FrameRef initialization")
    CASES.note()
    clean, _ = check.check_frames({"control.tkb":
        '// let mut frame: FrameRef[p];\n'
        'fn harmless() { uart_puts("let mut frame: FrameRef[p];"); }\n'})
    if clean:
        failures.append(f"comments or strings counted as frame mints: {clean}")
    failures += frames(
        "a function that is not a declared entry mints a frame",
        "fn sneaky() {\n    let mut f: FrameRef = frame_ref_from_entry(4096);\n}\n",
        "sneaky calls frame_ref_from_entry and is not one of its declared callers")
    failures += frames(
        "a frame address rebuilt from a record outside the declared set",
        "fn sneaky() {\n    let mut f: FrameRef = frame_ref_from_saved(0);\n}\n",
        "sneaky calls frame_ref_from_saved")
    failures += frames(
        "a new function that takes a frame as a bare usize",
        "fn sneaky(frame_sp: usize) {\n}\n",
        "sneaky takes a frame address as a bare usize")
    failures += frames(
        "a frame parameter under another spelling",
        "fn sneaky(successor_sp: usize) {\n}\n",
        "sneaky takes a frame address as a bare usize")

    if failures:
        for failure in failures:
            print(f"FAIL stack-proof-states controls: {failure}")
        return 1
    report_pass(
        "stack-proof-states controls",
        "the tree passes, and a start that takes Ready, a reap that takes "
        "Exited, a token minted outside the named functions, a token "
        "written as a literal, a check that no longer reads the stack owner, "
        "default frame initialization, and a frame minted or taken as a bare usize outside its declared "
        "set are each refused for their own reason",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
