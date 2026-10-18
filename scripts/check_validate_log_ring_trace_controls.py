#!/usr/bin/env python3
"""Controls for the log-ring trace parser (GitHub issue #656).

scripts/validate_log_ring_trace.py parses a log-ring trace window into the
module TLC checks against kernel/models/LogRingTrace.tla. The protocol
refusals need TLC and run in `make modelcheck`
(scripts/log_ring_trace_tlc_controls.py). These need nothing but the
parser, in this process: what it refuses about the REPORT, and the opening
state conventions the generated module rests on.

It also holds three lists to one another, as #606's controls do, since a
drift between them makes a negative control vacuous: the writer and reader
actions of LogRing.tla's Next, the actions LogRingTrace.tla offers by name
(`Allowed`), and the validator's ACTIONS, which `--without` accepts; and
the event kinds the trace spec matches against the kinds the parser reads.
"""

import importlib.util
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from pass_line import CaseCount, report_pass  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts" / "validate_log_ring_trace.py"
_spec = importlib.util.spec_from_file_location("validate_log_ring_trace",
                                               VALIDATOR)
V = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(V)
MODEL = ROOT / "kernel" / "models" / "LogRing.tla"
TRACE_SPEC = ROOT / "kernel" / "models" / "LogRingTrace.tla"
WINDOW = ROOT / "kernel" / "tests" / "qemu" / "log_ring_trace_synthetic.window"

CASES = CaseCount()


def window(events, lost=0, end=True, stored=None, cpus=2):
    stored = len(events) if stored is None else stored
    lines = [f"log-ring-trace: begin cpus={cpus} slots=4 head=8 "
             f"stored={stored} lost={lost}"]
    lines += [f"log-ring-trace: {event}" for event in events]
    if end:
        lines.append("log-ring-trace: end")
    return lines


GOOD = ["w0 reserve 8 1", "w0 claim 8 1 0 0x40012", "w0 write 8 1 0",
        "w0 commit 8 1 0"]


def refusal(name, lines, needle):
    CASES.note()
    try:
        V.trace_module(V.parse(lines))
    except V.TraceError as error:
        if needle in str(error):
            return True
        print(f"FAIL validate-log-ring-trace controls: {name}: refused with "
              f"{error!r}, expected {needle!r}")
        return False
    print(f"FAIL validate-log-ring-trace controls: {name}: accepted, "
          f"expected a refusal saying {needle!r}")
    return False


def holds_true(name, condition, detail=""):
    CASES.note()
    if not condition:
        print(f"FAIL validate-log-ring-trace controls: {name} {detail}")
    return bool(condition)


def model_actions():
    """The actions LogRing.tla's Next takes, by name."""
    text = MODEL.read_text(encoding="utf-8")
    body = text.split("\nNext ==", 1)[1].split("\nSpec ==", 1)[0]
    return set(re.findall(r"\b([A-Z]\w*)(?:\(w\))?\s*(?:\\/|$)", body,
                          re.MULTILINE)) - {"Done"}


def spec_actions():
    text = TRACE_SPEC.read_text(encoding="utf-8")
    return set(re.findall(r'Allowed\("(\w+)"\)', text))


def spec_kinds():
    text = TRACE_SPEC.read_text(encoding="utf-8")
    return set(re.findall(r'e\.kind = "(\w+)"', text))


def main() -> int:
    ok = True
    ok &= refusal("no window", ["boot"], "found 0")
    ok &= refusal("two windows", window(GOOD) + window(GOOD), "found 2")
    ok &= refusal("a cut report", window(GOOD, end=False), "no end line")
    ok &= refusal("a lost event", window(GOOD, lost=1), "lost 1 event")
    ok &= refusal("a miscounted header", window(GOOD, stored=5),
                  "says 5 event(s) and 4 arrived")
    ok &= refusal("an unknown kind", window(GOOD + ["w0 finalize 8 1 0"]),
                  "malformed event")
    ok &= refusal("a short claim", window(["w0 claim 8 1 0"]),
                  "malformed event")
    ok &= refusal("a cpu past the header", window(["w2 reserve 8 1"]),
                  "cpu 2 in a window of 2")
    ok &= refusal("a record past the model's K",
                  window(["w0 reserve 8 3"]), "outside LogRing.tla's bound")
    ok &= refusal("a slot index past its record",
                  window(["w0 write 8 1 1"]), "past its record")
    ok &= refusal("a Free word that is not zero",
                  window(["w0 claim 8 1 0 0x40010"]), "Free slot word")
    ok &= refusal("a reader event before its begin",
                  window(["r copy 8"]), "before its begin")
    ok &= refusal("a reader outcome the kind lacks",
                  window(["r begin 7 9", "r head 7 0x70012 kept"]),
                  "malformed event")

    # The opening state conventions.
    base, init = V.opening(V.parse(window(
        ["r begin 7 9", "w1 commit 9 2 0", "w0 reserve 10 1"] + [])))
    ok &= holds_true("the shift is a multiple of the slot count",
                     base % 4 == 0 and base <= 7, f"(base {base})")
    ok &= holds_true("a writer first seen committing starts in commit",
                     init["writers"][2] == ("commit", 9 - base, 2, 0),
                     f"({init['writers'][2]})")
    ok &= holds_true("its continuation starts Committed and written",
                     init["word"][10 % 4].state == "Committed"
                     and init["text"][10 % 4] == 10 - base,
                     f"({init['word'].get(2)}, {init['text'].get(2)})")
    ok &= holds_true("its first slot starts Reserved",
                     init["word"][9 % 4].state == "Reserved")
    ok &= holds_true("head is the lower of the header's and the first "
                     "reservation", init["head"] == 8 - base)
    ok &= holds_true("the reader starts at its first sequence",
                     init["rnext"] == 7 - base)
    _, init = V.opening(V.parse(window(
        ["w0 claim 12 1 0 0x80022", "w1 claim 16 1 0 0xc0022"])))
    ok &= holds_true("a slot starts at the earliest word seen for it",
                     init["word"][0] == V.Word(8, "Committed", 2),
                     f"({init['word'].get(0)})")

    # Three lists, one: LogRing.tla's Next, the trace spec's labels, and
    # what --without accepts.
    model, spec, ours = model_actions(), spec_actions(), set(V.ACTIONS)
    ok &= holds_true("LogRing.tla's Next was read", len(model) >= 10,
                     f"({sorted(model)})")
    ok &= holds_true("the trace spec labels every action of LogRing.tla's "
                     "Next", model == spec,
                     f"(model only {sorted(model - spec)}, trace spec only "
                     f"{sorted(spec - model)})")
    ok &= holds_true("--without accepts exactly the trace spec's labels",
                     spec == ours, f"(spec only {sorted(spec - ours)}, "
                     f"validator only {sorted(ours - spec)})")
    kinds = set(V.WRITER_KINDS) | set(V.READER_KINDS)
    ok &= holds_true("the trace spec matches every kind the parser reads",
                     spec_kinds() == kinds,
                     f"(spec only {sorted(spec_kinds() - kinds)}, parser "
                     f"only {sorted(kinds - spec_kinds())})")
    ok &= holds_true("the recorded window parses",
                     bool(V.trace_module(V.parse(
                         WINDOW.read_text(encoding="utf-8").splitlines()))))
    if not ok:
        return 1
    report_pass(
        "validate-log-ring-trace controls",
        "the parser refuses a missing, doubled, cut, lossy or miscounted "
        "window and malformed, out-of-bound or misplaced events; the opening "
        "state conventions hold; LogRing.tla's Next, LogRingTrace.tla's "
        "labels and --without are one list, and the trace spec matches "
        "every event kind the parser reads",
        cases=CASES.ran, actions=len(model))
    return 0


if __name__ == "__main__":
    sys.exit(main())
