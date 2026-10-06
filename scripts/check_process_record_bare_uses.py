#!/usr/bin/env python3
"""Keep ProcessRecord's trusted mints and destructive contracts explicit.

Bare record lookup is forbidden in the production source. The
compiler checks loans at marked deletion boundaries; this source check keeps
those markers and the private ownership mint from silently disappearing. It
reads tracked source only and does not prove the mint or allocator protocol.
"""

from collections import Counter
import pathlib
import re
import sys

from pass_line import report_pass

PATH = pathlib.Path("kernel/kernel/process.tkb")
BUDGET = 0
RAW_CALLS = Counter()
OWNER_MINTS = Counter({name: 1 for name in (
    "scheduled_process_alloc_finish",
    "scheduled_process_ready_take",
    "scheduled_process_constructing_take",
    "scheduled_process_exited_take",
    "scheduled_process_running_take",
    "scheduled_process_blocked_take",
    "kernel_process_clone_begin",
)})
CONTRACTS = {
    "scheduled_process_transfer_owned_loan": "loan_transfer",
    "scheduled_process_transfer_locked_loan": "loan_transfer",
    "scheduled_process_transfer_current_loan": "loan_transfer",
    "scheduled_process_slot_remove": "record_mutates_ProcessRunGuard",
    "scheduled_process_reap_remove": "record_mutates_ScheduledProcessOwner",
}
PRIVATE = (
    "scheduled_process_owner_new", "process_running_new",
    "scheduled_process_transfer_owned_loan",
    "scheduled_process_transfer_locked_loan",
    "scheduled_process_transfer_current_loan",
    "scheduled_process_locked_view_new",
    "scheduled_process_current_view_new",
)
FN_RE = re.compile(r"^(private )?(?:inline |noinline )?fn (\w+)\(")
CALL_RE = re.compile(r"\bscheduled_process_record_(at|of)\s*\(")
OWNER_RE = re.compile(r"\bscheduled_process_owner_new\s*\(")


def problems(text: str) -> list[str]:
    raw = Counter()
    owners = Counter()
    bodies: dict[str, list[str]] = {}
    private = set()
    enclosing = "<file scope>"
    for line in text.splitlines():
        code = line.split("//", 1)[0]
        match = FN_RE.match(code)
        if match:
            enclosing = match[2]
            bodies[enclosing] = []
            if match[1]:
                private.add(enclosing)
        if enclosing in bodies:
            bodies[enclosing].append(code)
        calls = code[match.end():] if match else code
        raw.update((enclosing, m[1]) for m in CALL_RE.finditer(calls))
        owners[enclosing] += len(OWNER_RE.findall(calls))
    owners = +owners
    result = []
    if sum(raw.values()) != BUDGET or raw != RAW_CALLS:
        result.append("bare record lookup must remain absent")
    if owners != OWNER_MINTS:
        result.append("scheduled ownership mints differ from the seven "
                      "reviewed allocation/state-transfer bodies")
    if not re.search(r"^private linear view ProcessCurrent\[", "\n".join(
            line.split("//", 1)[0] for line in text.splitlines()), re.M):
        result.append("ProcessCurrent must remain a private view mint")
    for name in PRIVATE:
        if name not in private:
            result.append(f"{name} must remain private to its mint module")
    for name, required in CONTRACTS.items():
        body = "\n".join(bodies.get(name, []))
        header = re.match(r"^(?:private )?(?:inline |noinline )?fn \w+\([\s\S]*?\)\s*(?:->[^{}]+)?!\{([^}]*)\}", body)
        effects = [] if header is None else [word.strip() for word in header[1].split(",")]
        if required not in effects:
            result.append(f"{name} must declare {required} at its reviewed loan boundary")
    return result


def main() -> int:
    source = PATH.read_text()
    failures = problems(source)
    if failures:
        for failure in failures:
            print("FAIL process-record-bare-uses: " + failure, file=sys.stderr)
        return 1
    report_pass("process-record-bare-uses",
                "no bare lookup, seven ownership mint bodies, "
                "private constructors, owned loan transfer and both destructive contracts",
                lines=len(source.splitlines()), owner_mints=sum(OWNER_MINTS.values()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
