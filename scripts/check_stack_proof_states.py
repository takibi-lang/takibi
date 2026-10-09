#!/usr/bin/env python3
"""Keep the stack-free proof of a process start and a zombie reap in one place.

GitHub issue #614. StackOwnership.tla's StartsOnFreeStack says a process is
started, or reaped, only while no other core stands on its kernel stack. The
type checker enforces half of that: `scheduled_process_start` takes a
`ProcessState::Startable` token and `scheduled_process_reap_remove` a
`ProcessState::Reapable` one, and a Ready or Exited token is rejected as a
static value mismatch. It cannot enforce the other half: the tokens are made
by a few functions in kernel/kernel/process.tkb, and it is those functions'
reading of `stack_owner_cpu` that makes the proof true. Nothing stops a later
edit from loosening a signature back to Ready, or from minting a token in a
new place without reading the owner. This check pins the shape:

- start takes only Startable, and reap_remove only Reapable (the combined
  reap that also took it is gone, #693 step 5);
- the state constructors are called only from the named mint functions, and
  a token is never written as a literal anywhere else;
- every mint function reads `stack_owner_cpu`.

The same file also pins the frame handle (GitHub issue #661, #637 stage 1 group
C). A saved exception frame is a `FrameRef`, made only by `frame_ref_from_entry`
(an assembly or generated entry hands over the address, or a probe stands one
in), `frame_ref_from_saved` (rebuilt from a process record's saved_sp, for the
process whose owner the one caller `scheduled_process_saved_frame` holds) and
`maybe_frame_from_entry`; the callers of each are a declared set, and a
parameter named for a frame address (`frame_sp`, `current_sp`, ...) is a bare
`usize` only in the declared seams, where an assembly ABI or a stack-bound
comparison needs an integer.

Direct default FrameRef declarations are refused as well: private affine
fields otherwise allow an uninitialized local to bypass these explicit
mints. This lexical rule does not cover arbitrary aggregate initialization.

What a PASS says is that the explicit trusted set is still the named one. It does not
say the read is right; the runtime check in start and exited_take, and the
protocol-trace replay's StartsOnFreeStack, are what watch that.
"""

from pathlib import Path
import re
import sys

from pass_line import report_pass
from check_model_function_map import masked_sources

SOURCE = Path("kernel/kernel/process.tkb")

STARTABLE_MINTS = {"scheduled_process_ready_take",
                   "scheduled_process_start_check",
                   "scheduled_process_restart_check"}
REAPABLE_MINTS = {"scheduled_process_exited_take"}
CONSUMERS = {
    "scheduled_process_start": "Startable",
    "scheduled_process_reap_remove": "Reapable",
}
CONSTRUCTORS = {"scheduled_process_startable_state": STARTABLE_MINTS,
                "scheduled_process_reapable_state": REAPABLE_MINTS}
LITERALS = {"Startable": "scheduled_process_startable_state",
            "Reapable": "scheduled_process_reapable_state"}

FUNCTION_RE = re.compile(r"^(?:private )?(?:inline |noinline )?fn (\w+)\(", re.M)

# The callers of each frame mint, by function name, with why each is one.
FRAME_MINT_CALLERS = {
    "frame_ref_from_entry": {
        # The assembly and generated entries, which receive a frame in x0.
        "kernel_syscall_block_return", "kernel_syscall_resume_return",
        "kernel_syscall_clone_child_return",
        "kernel_syscall_child_exec_return",
        "kernel_syscall_clone_parent_return", "kernel_syscall_migrate_return",
        "kernel_process_stack_switch_complete", "platform_irq_dispatch",
        "platform_el0_irq_dispatch", "maybe_frame_from_entry",
        # The debugger and the crash reporter, declared mint code by design.
        "ddb_current_unwind_root", "kernel_ddb_sync_dispatch",
        "crash_snapshot_capture",
        # Boot-time probes that stand in frames which are not real ones.
        "kernel_process_probe_tick_address",
        "kernel_process_trace_block_wake_probe",
        "kernel_process_scheduler_probe",
    },
    "frame_ref_from_saved": {
        # A frame rebuilt from a process record's saved_sp, indexed by the
        # owner of that record: every delivery into another process's frame
        # and every scheduler pickup goes through this one function.
        "scheduled_process_saved_frame",
        # A child's frame, placed at the top of its new stack and then copied.
        "kernel_syscall_clone_child_return",
    },
    "maybe_frame_from_entry": {"kernel_syscall_dispatch"},
}

# Parameter names that mean "a frame address". As a bare usize they are
# allowed only here: an assembly ABI seam, or an address compared with a
# stack's bounds.
FRAME_PARAM_RE = re.compile(
    r"\b(?:frame_sp|current_sp|parent_sp|child_sp|next_sp|successor_sp)\s*:\s*usize")
# Affine private fields do not prohibit default initialization. Refuse the
# direct zero-mint shape; aggregate construction needs a compiler rule.
FRAME_DEFAULT_RE = re.compile(
    r"\blet\s+(?:mut\s+)?\w+\s*:\s*FrameRef(?:\s*\[[^\]]+\])?\s*;")
FRAME_USIZE_SEAMS = {
    "kernel_syscall_block_return", "kernel_syscall_resume_return",
    "kernel_syscall_clone_child_return", "kernel_syscall_child_exec_return",
    "kernel_syscall_clone_parent_return", "kernel_syscall_migrate_return",
    "kernel_process_stack_switch_complete", "platform_irq_dispatch",
    "platform_el0_irq_dispatch", "kernel_syscall_dispatch",
    "kernel_stack_guard_check", "kernel_stack_guard_check_interrupt",
    "kernel_stack_guard_inspect", "maybe_frame_from_entry",
    "frame_ref_from_entry", "frame_ref_from_saved",
    # The debugger and crash reporter read frames as integers by design.
    "kernel_ddb_enter", "kernel_ddb_sync_dispatch",
    "kernel_ddb_stopped_root_publish", "el1_exception_evidence_from_frame",
    "crash_snapshot_capture", "kernel_invariant_evidence",
    "kernel_process_crash_frame_usable", "ddb_stopped_root_check",
    "ddb_bt_test_stopped_check", "kernel_ddb_enter_stopped",
}


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


def check_frames(files: dict[str, str]) -> tuple[list[str], int]:
    """Frame-handle rules over every kernel source: path -> text."""
    failures = []
    examined = 0
    for path, text in sorted(files.items()):
        for match in FRAME_DEFAULT_RE.finditer(masked_sources(text)):
            line = text.count("\n", 0, match.start()) + 1
            failures.append(f"{path}:{line}: default FrameRef initialization "
                            "bypasses the declared frame mints")
        for name, (signature, body) in functions(text).items():
            examined += 1
            for mint, callers in FRAME_MINT_CALLERS.items():
                if name != mint and re.search(rf"\b{mint}\(", body) and \
                        name not in callers:
                    failures.append(
                        f"{path}: {name} calls {mint} and is not one of its "
                        "declared callers")
            if FRAME_PARAM_RE.search(" ".join(signature.split())) and \
                    name not in FRAME_USIZE_SEAMS:
                failures.append(
                    f"{path}: {name} takes a frame address as a bare usize, "
                    "and is not a declared seam")
    return failures, examined


def kernel_sources() -> dict[str, str]:
    return {path.as_posix(): path.read_text(encoding="utf-8")
            for path in sorted(Path("kernel").rglob("*.tkb"))}


def main() -> int:
    failures, examined = check(SOURCE.read_text(encoding="utf-8"))
    frame_failures, frame_examined = check_frames(kernel_sources())
    failures += frame_failures
    examined += frame_examined
    for failure in failures:
        print(f"ERROR stack-proof-states: {failure}")
    if failures:
        print("FAIL stack-proof-states: the stack-free proof is no longer "
              "made in the named places")
        return 1
    report_pass(
        "stack-proof-states",
        f"start takes only Startable and reap only Reapable; frame handles "
        f"use declared callers of {len(FRAME_MINT_CALLERS)} mints and no "
        f"direct default initialization; "
        f"{len(STARTABLE_MINTS) + len(REAPABLE_MINTS)} mint functions read "
        f"stack_owner_cpu and nothing else builds the tokens "
        f"({examined} functions read)",
        functions=examined)
    return 0


if __name__ == "__main__":
    sys.exit(main())
