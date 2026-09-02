#!/usr/bin/env python3
"""The dead-slot-tolerant record peek's result must be read, never bound.

`scheduled_process_record_peek` exists so that crash and trace paths can ask
about a process that may ALREADY HAVE BEEN REAPED. Its own header says so, and
that is why it hands back the counted absent record instead of reporting a
miss the way the ordinary accessor does.

That tolerance is safe for exactly one shape of caller: read a field and
return the value. It stops being safe the moment somebody writes

    let record = scheduled_process_record_peek(slot);

because the pointer may name a record that no longer exists, and nothing about
the binding says so. Every one of today's six callers is a one-field accessor
-- `pid_of_slot`, `peek_state`, `peek_wait_reason`, `peek_saved_sp`,
`pid_of_handle`, `crash_parent_pid` -- and the property they share is
syntactic: the call is immediately followed by `.field`.

So the check is that shape, not an allowlist of callers. An allowlist would
have to be maintained and would still permit a listed caller to start binding
the pointer; this permits neither, and needs no upkeep when a seventh
one-field accessor is added.

Deliberately syntactic and deliberately narrow. It does not prove the field
read is meaningful on a dead record -- the absent record's fields are zeroes,
and whether a zero pid is a sensible answer is the caller's judgment. What it
prevents is the pointer outliving the expression, which is the part no reader
can check by looking at one line.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

KERNEL = pathlib.Path("kernel")
PEEK = "scheduled_process_record_peek"
DEFINITION_RE = re.compile(r"^(?:private )?fn " + PEEK + r"\b")
# The call, then a balanced-enough argument list, then the field access. The
# argument lists here are one identifier or one field path, never nested
# calls with parentheses, so a non-greedy match to the first ')' is exact.
GOOD_RE = re.compile(re.escape(PEEK) + r"\([^()]*\)\s*\.")
ANY_RE = re.compile(r"\b" + re.escape(PEEK) + r"\s*\(")


def main():
    if not KERNEL.is_dir():
        print("FAIL dead-slot-peek: kernel/ not found", file=sys.stderr)
        return 1

    calls = 0
    failures = []
    for path in sorted(KERNEL.rglob("*.tkb")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if DEFINITION_RE.match(line):
                continue
            if not ANY_RE.search(line):
                continue
            calls += 1
            if not GOOD_RE.search(line):
                failures.append(
                    "%s:%d: %s's result is not read as a field on the spot. "
                    "It may name a reaped record, so the pointer must not "
                    "outlive the expression -- read the field here, or use "
                    "the counted accessor if the record is supposed to exist"
                    % (path, number, PEEK))

    if failures:
        for line in failures:
            print("FAIL dead-slot-peek: " + line, file=sys.stderr)
        return 1

    if calls == 0:
        print("FAIL dead-slot-peek: no call to %s found, so this check is "
              "no longer looking at anything" % PEEK, file=sys.stderr)
        return 1

    print("PASS dead-slot-peek: %d call(s) to %s, each read as a field on "
          "the spot" % (calls, PEEK))
    return 0


if __name__ == "__main__":
    sys.exit(main())
