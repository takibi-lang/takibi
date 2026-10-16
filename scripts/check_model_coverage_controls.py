#!/usr/bin/env python3
"""Controls for scripts/model_coverage.py (GitHub issue #802).

The coverage check refuses a fully explored TLC run in which an action was
never taken unless the allow-list names it with a reason, and refuses an
allow-list entry that is malformed or stale. make modelcheck runs it on real
logs (and its own live control on StackOwnership's dead CloneReschedule);
these cases pin the parsing on synthetic logs, with no TLC.
"""

import sys

sys.dont_write_bytecode = True
import model_coverage as cov  # noqa: E402
from pass_line import CaseCount, report_pass  # noqa: E402

HEAD = "The coverage statistics at 2026-10-16 10:00:00\n"


def log(*rows: tuple[str, int, int]) -> str:
    lines = [HEAD, "<Init line 1, col 1 to line 1, col 4 of module M>: 1:1"]
    for n, (action, distinct, generated) in enumerate(rows, 10):
        lines.append(f"<{action} line {n}, col 1 to line {n}, col 5 of module M>: "
                     f"{distinct}:{generated}")
        lines.append(f"  line {n}, col 8 to line {n}, col 20 of module M: 3")
    lines.append("<TypeOK line 90, col 1 to line 90, col 6 of module M>")
    lines.append("End of statistics.")
    return "\n".join(lines) + "\n"


def main() -> int:
    count = CaseCount()

    def case(name, allow, runs, expect_ok, fragment=None):
        errors, _ = cov.judge(allow, runs)
        assert (not errors) == expect_ok, f"{name}: {errors}"
        if fragment is not None:
            assert any(fragment in e for e in errors), f"{name}: {errors}"
        count.note()

    live = log(("A", 2, 5), ("B", 0, 3))
    dead = log(("A", 2, 5), ("B", 0, 0))
    case("all actions taken", "", [("M", "fixed", live)], True)
    # Generated 0 is dead even when another action ran; distinct 0 alone
    # (taken, but only to seen states) is not.
    case("dead action refused", "", [("M", "fixed", dead)], False,
         "action B (line 11) is never taken")
    case("allow-listed dead action", "M fixed B: only the faulty variant\n",
         [("M", "fixed", dead)], True)
    case("entry for another variant does not cover", "M other B: reason\n",
         [("M", "fixed", dead)], False, "never taken")
    case("stale entry: action is taken", "M fixed B: reason\n",
         [("M", "fixed", live)], False, "IS taken now")
    case("stale entry: no such action", "M fixed Gone: reason\n",
         [("M", "fixed", live)], False, "has no action Gone")
    case("stale entry: run not judged", "M gone B: reason\n",
         [("M", "fixed", live)], False, "no fully explored TLC run")
    case("entry without reason", "M fixed B:\n", [("M", "fixed", dead)], False,
         "allow-list line 1")
    case("duplicate entry", "M fixed B: r\nM fixed B: r\n",
         [("M", "fixed", dead)], False, "duplicate entry")
    case("log without coverage", "", [("M", "fixed", "No error has been found.\n")],
         False, "no action coverage")
    # A long run prints a report a minute; only the last one is the verdict.
    case("early report superseded", "", [("M", "fixed", dead + live)], True)
    case("late report still dead", "", [("M", "fixed", live + dead)], False,
         "never taken")
    # A dead second occurrence of an action is a dead disjunct.
    case("dead second occurrence", "",
         [("M", "fixed", log(("A", 2, 5), ("A", 0, 0)))], False, "action A")

    report_pass("model-coverage controls",
                f"{count.ran} scenarios: dead actions, allow-list entries and "
                f"report selection judged as specified",
                scenarios=count.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
