#!/usr/bin/env python3
"""Keep ProcessRecord's trusted mints and destructive contracts explicit.

Raw record lookup is confined to five private/authority accessor bodies. The
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
BUDGET = 5
RAW_CALLS = Counter({
    ("scheduled_process_record_of", "at"): 1,
    ("scheduled_process_record_locked", "at"): 1,
    ("scheduled_process_record_of_locked", "of"): 1,
    ("scheduled_process_record_running", "of"): 1,
    ("scheduled_process_record_owned", "at"): 1,
})
OWNER_MINTS = Counter({name: 1 for name in (
    "scheduled_process_alloc_finish",
    "scheduled_process_ready_take",
    "scheduled_process_constructing_take",
    "scheduled_process_exited_take",
    "scheduled_process_running_take",
    "scheduled_process_blocked_take",
    "kernel_process_clone_begin",
)})
DESTRUCTIVE = {
    "scheduled_process_slot_remove": "record_mutates_ProcessRunGuard",
    "scheduled_process_reap_remove": "record_mutates_ScheduledProcessOwner",
}
PRIVATE = (
    "scheduled_process_record_at", "scheduled_process_record_of",
    "scheduled_process_owner_new", "process_running_new",
)
FN_RE = re.compile(r"^(private )?fn (\w+)\(")
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
        result.append("raw record lookup must occur exactly once in each of "
                      "the five declared accessor bodies")
    if owners != OWNER_MINTS:
        result.append("scheduled ownership mints differ from the seven "
                      "reviewed allocation/state-transfer bodies")
    for name in PRIVATE:
        if name not in private:
            result.append(f"{name} must remain private to its mint module")
    for name, required in DESTRUCTIVE.items():
        body = "\n".join(bodies.get(name, []))
        header = re.match(r"^(?:private )?fn \w+\([\s\S]*?\)\s*!\{([^}]*)\}", body)
        effects = [] if header is None else [word.strip() for word in header[1].split(",")]
        if required not in effects:
            result.append(f"{name} must declare {required} at its destructive boundary")
    return result


def main() -> int:
    failures = problems(PATH.read_text())
    if failures:
        for failure in failures:
            print("FAIL process-record-bare-uses: " + failure, file=sys.stderr)
        return 1
    report_pass("process-record-bare-uses",
                "five declared raw lookup bodies, seven ownership mint bodies, "
                "private constructors and both destructive loan contracts",
                uses=BUDGET, owner_mints=sum(OWNER_MINTS.values()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
