#!/usr/bin/env python3
"""Check a kernel log-ring trace window against LogRing.tla with TLC.

GitHub issue #656 (retargeted 2026-10-18 to kernel/models/LogRing.tla), in
the shape of #606's scripts/validate_protocol_trace.py. A window of the
kernel log ring (kernel/printk/log.tkb) is printed as one stream of events
per writing CPU and one for the reader, each event one serialization point
of LogRing.tla with the sequence, record and observed slot word. This
script only PARSES that window into the TLA+ module LogRingTraceData and
asks TLC whether kernel/models/LogRingTrace.tla accepts it: whether some
interleaving of the streams is a behaviour of LogRing.tla with every
observed word equal to the model's. No enabling condition, effect or
invariant is written here.

What this script refuses itself, because it is about the report and not
the protocol: no window, two windows, a malformed line, a window that lost
events or was cut short, a record wider than the model's K = 2 (outside
its bound, as #606 refuses a reparented process), and -- one policy -- an
action the probe exists to exercise that the matched behaviour never took
(REQUIRED).

The opening state is not printed by the kernel: a snapshot taken while
other CPUs write is torn. It is taken from the events, by conventions that
are about the report, each one checked by TLC from there on:
- head: the lower of the head the opener read and the first reservation
  in the window (a reservation between the window opening and that read is
  recorded, and is below it);
- a slot's word: the earliest value any event observed or implies for it,
  in the order a slot word moves (sequence, then Reserved before Committed
  or Discarded). A word that moved any other way makes some event's
  observed word disagree with the model, which TLC refuses;
- a writer whose first event is not a reservation reserved before the
  window: it starts in the state that event needs (claim, write or commit
  of the record and slot the event names), its earlier slots claimed and,
  past write, written;
- a slot's text: its own sequence when it starts Committed or written;
- the reader: at the first sequence it reads, everything before returned.

Wire format, every line prefixed "log-ring-trace: ":
  begin cpus=C slots=N head=H stored=S lost=L
  w<cpu> reserve FIRST K
  w<cpu> claim|refuse|commitlost FIRST K I WORD
  w<cpu> write|commit FIRST K I
  r begin FIRST END
  r head SEQ WORD copy|lost|skip
  r copy SEQ
  r check SEQ WORD kept|lost|cont
  r ccopy SEQ WORD copy|lost
  r ccheck SEQ WORD kept|lost
  end
WORD is the raw slot word, seq << 16 | cpu << 8 | span << 4 | state
(0 Free, 1 Reserved, 2 Committed, 3 Discarded), decimal or 0x hex. Lines
of one stream are in that stream's program order.

Every event but `r begin` may end in `@T0+D`: the system counter read
before its atomic access (T0) and how much later it was read again after
it (D). The counter is one per system, so an event whose interval ends
before another's begins (by more than COUNTER_MARGIN ticks) happened
first, and TLC is held to interleavings that agree (LogRingTrace.tla,
InOrder). An event without one is ordered by nothing but its stream.

Usage: validate_log_ring_trace.py UART_LOG [--without ACTION]
       [--model NAME=BOOL ...]
Exit code only (0 = pass, 1 = fail).
"""

import argparse
import dataclasses
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "kernel" / "models"
SPECS = (MODELS / "LogRingTrace.tla", MODELS / "LogRing.tla")

_spec = importlib.util.spec_from_file_location(
    "validate_protocol_trace", ROOT / "scripts" / "validate_protocol_trace.py")
_PT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_PT)

LINE_RE = re.compile(r"^log-ring-trace: (.*)$")
BEGIN_RE = re.compile(
    r"^begin cpus=(\d+) slots=(\d+) head=(\d+) stored=(\d+) lost=(\d+)$")

# LogRing.tla's Next, by the names LogRingTrace.tla labels (Done excepted:
# it is the model's terminal stutter, not a kernel step).
WRITER_ACTIONS = ("Reserve", "Claim", "Refuse", "Write", "Commit",
                  "CommitLost")
READER_ACTIONS = ("ReadHead", "HeadCopy", "HeadCheck", "ContCopy",
                  "ContCheck")
ACTIONS = WRITER_ACTIONS + READER_ACTIONS
MODEL_CONSTANTS = ("TRUST_RESERVED", "CHECK_PREV", "CONT_SEQ",
                   "REPORT_REFUSAL")
FIXED = {"TRUST_RESERVED": False, "CHECK_PREV": True, "CONT_SEQ": True,
         "REPORT_REFUSAL": True}
# LogRing.tla's K: the widest record the model has.
MODEL_K = 2
# Counter ticks of slack before one interval is taken to precede another.
COUNTER_MARGIN = 2
# An unstamped event's interval: [0, UNSTAMPED], which overlaps everything.
# TLC's integers are 32-bit, so stamps are rebased and must stay below it.
UNSTAMPED = 1 << 30
STAMP_RE = re.compile(r"^@(\d+)\+(\d+)$")

# What the window's probe makes happen on every run, whatever the timing.
# Refusals, lost commits and two-slot records depend on timing and line
# length: checked when they happen, not required.
REQUIRED = (("Reserve",), ("Claim",), ("Write",), ("Commit",),
            ("ReadHead",), ("HeadCopy",), ("HeadCheck",))

STATES = {0: "Free", 1: "Reserved", 2: "Committed", 3: "Discarded"}
WRITER_KINDS = {"reserve": 2, "claim": 4, "refuse": 4, "commitlost": 4,
                "write": 3, "commit": 3}
READER_KINDS = {"head": ("copy", "lost", "skip"), "copy": None,
                "check": ("kept", "lost", "cont"), "ccopy": ("copy", "lost"),
                "ccheck": ("kept", "lost")}
STATE_RANK = {"Free": 0, "Reserved": 1, "Committed": 2, "Discarded": 2}


class TraceError(Exception):
    pass


@dataclasses.dataclass(frozen=True)
class Word:
    seq: int      # -1 for Free
    state: str
    span: int

    def key(self):
        return (self.seq, STATE_RANK[self.state])


def decode(token):
    try:
        raw = int(token, 0)
    except ValueError:
        raise TraceError(f"malformed slot word {token!r}") from None
    state = STATES[raw & 3]
    if state == "Free":
        if raw != 0:
            raise TraceError(f"a Free slot word that is not 0: {token}")
        return Word(-1, "Free", 0)
    return Word(raw >> 16, state, (raw >> 4) & 15)


@dataclasses.dataclass
class Event:
    stream: int          # 0 reader, c + 1 for CPU c
    kind: str
    first: int = 0
    k: int = 0
    i: int = 0
    seq: int = 0
    word: Word = None
    out: str = ""
    line: str = ""
    t0: int = None       # counter before; None when the line had no stamp
    t1: int = None       # counter after


@dataclasses.dataclass
class Window:
    cpus: int
    slots: int
    head: int
    streams: dict        # stream -> [Event]
    reader_first: int = None
    reader_end: int = None


def number(token, text):
    if not token.isdigit():
        raise TraceError(f"malformed event: {text}")
    return int(token)


def parse(lines):
    """The one window in the log."""
    body = [m.group(1) for m in (LINE_RE.match(line) for line in lines) if m]
    begins = [i for i, text in enumerate(body) if text.startswith("begin ")]
    if len(begins) != 1:
        raise TraceError(f"expected one log-ring-trace window, found "
                         f"{len(begins)}")
    header = BEGIN_RE.match(body[begins[0]])
    if not header:
        raise TraceError(f"malformed header: {body[begins[0]]}")
    cpus, slots, head, stored, lost = (int(g) for g in header.groups())
    events = body[begins[0] + 1:]
    if not events or events[-1] != "end":
        raise TraceError("the window has no end line: the report was cut")
    events = events[:-1]
    if lost:
        raise TraceError(f"the window lost {lost} event(s); a check with a "
                         "gap in it proves nothing")
    if len(events) != stored:
        raise TraceError(f"the header says {stored} event(s) and "
                         f"{len(events)} arrived")
    window = Window(cpus, slots, head, {0: []})
    for c in range(cpus):
        window.streams[c + 1] = []
    for text in events:
        fields = text.split()
        if len(fields) < 2:
            raise TraceError(f"malformed event: {text}")
        stamp = None
        if fields[-1].startswith("@"):
            match = STAMP_RE.match(fields[-1])
            if not match:
                raise TraceError(f"malformed stamp: {text}")
            stamp = (int(match.group(1)), int(match.group(1)) +
                     int(match.group(2)))
            fields = fields[:-1]
        who, kind, args = fields[0], fields[1], fields[2:]
        if stamp is not None and who == "r" and kind == "begin":
            raise TraceError(f"the reader's begin carries no stamp: {text}")
        if who == "r":
            if kind == "begin":
                if window.reader_first is not None or window.streams[0]:
                    raise TraceError("the reader's begin is not its first "
                                     f"and only one: {text}")
                if len(args) != 2:
                    raise TraceError(f"malformed event: {text}")
                window.reader_first = number(args[0], text)
                window.reader_end = number(args[1], text)
                continue
            if window.reader_first is None:
                raise TraceError(f"a reader event before its begin: {text}")
            if kind not in READER_KINDS:
                raise TraceError(f"malformed event: {text}")
            outs = READER_KINDS[kind]
            want = 1 if outs is None else 3
            if len(args) != want:
                raise TraceError(f"malformed event: {text}")
            event = Event(0, kind, seq=number(args[0], text), line=text)
            if stamp:
                event.t0, event.t1 = stamp
            if outs is not None:
                event.word = decode(args[1])
                if event.word.span > MODEL_K:
                    raise TraceError(
                        f"a record of {event.word.span} slot(s) is outside "
                        f"LogRing.tla's bound K = {MODEL_K}: {text}")
                if args[2] not in outs:
                    raise TraceError(f"malformed event: {text}")
                event.out = args[2]
            window.streams[0].append(event)
            continue
        match = re.fullmatch(r"w(\d+)", who)
        if not match or kind not in WRITER_KINDS:
            raise TraceError(f"malformed event: {text}")
        cpu = int(match.group(1))
        if cpu >= cpus:
            raise TraceError(f"an event of cpu {cpu} in a window of {cpus} "
                             f"cpu(s): {text}")
        want = WRITER_KINDS[kind]
        if len(args) != want:
            raise TraceError(f"malformed event: {text}")
        first, k = number(args[0], text), number(args[1], text)
        if not 1 <= k <= MODEL_K:
            raise TraceError(f"a record of {k} slot(s) is outside "
                             f"LogRing.tla's bound K = {MODEL_K}: {text}")
        event = Event(cpu + 1, kind, first=first, k=k, seq=first, line=text)
        if stamp:
            event.t0, event.t1 = stamp
        if want >= 3:
            event.i = number(args[2], text)
            if event.i >= k:
                raise TraceError(f"slot index past its record: {text}")
            event.seq = first + event.i
        if want == 4:
            event.word = decode(args[3])
        window.streams[cpu + 1].append(event)
    for stream, items in window.streams.items():
        stamped = [e for e in items if e.t0 is not None]
        for before, after in zip(stamped, stamped[1:]):
            if after.t0 < before.t1:
                raise TraceError("a stream's stamps go backwards: "
                                 f"{before.line} then {after.line}")
    return window


def stamps(window):
    """{id(event): (t0, t1)}, rebased so TLC's integers hold them."""
    every = [e for es in window.streams.values() for e in es]
    stamped = [e for e in every if e.t0 is not None]
    low = min((e.t0 for e in stamped), default=0) - 1
    out = {}
    for e in every:
        if e.t0 is None:
            out[id(e)] = (0, UNSTAMPED)
            continue
        t0, t1 = e.t0 - low, e.t1 - low
        if t1 >= UNSTAMPED:
            raise TraceError(f"the window spans more than {UNSTAMPED} counter "
                             f"ticks: {e.line}")
        out[id(e)] = (t0, t1)
    return out


# --------------------------------------------------------------------------
# The opening state, from the events (conventions in the module docstring).


def mark(k, i):
    return k if i == 0 else 0


def implied_words(window):
    """Every (slot seq, Word) an event observed or implies."""
    words = []
    for stream, events in window.streams.items():
        for event in events:
            if event.word is not None:
                words.append((event.seq, event.word))
            if event.kind in ("claim", "write", "commit"):
                words.append((event.seq, Word(event.seq, "Reserved",
                                              mark(event.k, event.i))))
        if stream and events and events[0].kind != "reserve":
            first = events[0]
            for j in range(first.k):
                seq = first.first + j
                held = Word(seq, "Reserved", mark(first.k, j))
                if first.kind in ("claim", "refuse") and j < first.i:
                    words.append((seq, held))
                elif first.kind == "write":
                    words.append((seq, held))
                elif first.kind in ("commit", "commitlost"):
                    words.append((seq, held if j <= first.i else
                                  Word(seq, "Committed", mark(first.k, j))))
    return words


def opening(window):
    """(base, init) -- the shift and the state the window opens in."""
    n = window.slots
    seqs = [seq for seq, _ in implied_words(window)]
    seqs += [w.seq for _, w in implied_words(window) if w.seq >= 0]
    seqs += [e.first for s, es in window.streams.items() if s for e in es]
    seqs.append(window.head)
    if window.reader_first is not None:
        seqs += [window.reader_first, window.reader_end]
    base = (min(seqs) // n) * n if seqs else 0

    def rel(seq):
        return seq - base if seq >= 0 else -1

    reserves = [e.first for es in window.streams.values() for e in es
                if e.kind == "reserve"]
    head = rel(min([window.head] + reserves))
    word = {}
    for seq, w in implied_words(window):
        slot = seq % n
        if slot not in word or w.key() < word[slot].key():
            word[slot] = w
    text = {}
    for slot, w in word.items():
        if w.state == "Committed":
            text[slot] = rel(w.seq)
    writers = {}
    for stream in range(1, window.cpus + 1):
        events = window.streams[stream]
        if not events or events[0].kind == "reserve":
            writers[stream] = ("idle", 0, 0, 0)
            continue
        first = events[0]
        pc = {"claim": "claim", "refuse": "claim", "write": "write",
              "commit": "commit", "commitlost": "commit"}[first.kind]
        writers[stream] = (pc, rel(first.first), first.k, first.i)
        if pc in ("write", "commit"):
            done = first.i if pc == "write" else first.k
            for j in range(done):
                text[(first.first + j) % n] = rel(first.first + j)
    reader = rel(window.reader_first) if window.reader_first is not None \
        else 0
    return base, dict(head=head, word=word, text=text, writers=writers,
                      rnext=reader)


# --------------------------------------------------------------------------
# The module TLC reads.


def tla_word(w, base):
    seq = w.seq - base if w.seq >= 0 else -1
    return f'[seq |-> {seq}, st |-> "{w.state}", span |-> {w.span}]'


FREE = Word(-1, "Free", 0)


def trace_module(window):
    base, init = opening(window)
    n = window.slots
    every = [e for es in window.streams.values() for e in es]
    top = max([init["head"], init["rnext"]] +
              [e.seq - base for e in every] +
              [e.first - base + e.k for e in every if e.stream] +
              [e.word.seq - base for e in every
               if e.word is not None and e.word.seq >= 0] + [0])
    max_seq = top + 2 * MODEL_K + 2

    when = stamps(window)

    def event(e):
        w = tla_word(e.word or FREE, base)
        t0, t1 = when[id(e)]
        return (f'[kind |-> "{e.kind}", first |-> {e.first - base}, '
                f'k |-> {e.k}, i |-> {e.i}, seq |-> {e.seq - base}, '
                f'w |-> {w}, out |-> "{e.out}", t0 |-> {t0}, t1 |-> {t1}]')

    streams = []
    for stream in sorted(window.streams):
        body = ",\n    ".join(event(e) for e in window.streams[stream])
        streams.append(f"<<{body}>>" if body else "<<>>")
    words = ", ".join(
        tla_word(init["word"].get(slot, FREE), base) for slot in range(n))
    texts = ", ".join(str(init["text"].get(slot, -1)) for slot in range(n))
    writers = [init["writers"][s] for s in range(1, window.cpus + 1)]

    def column(index, quote=False):
        cells = [f'"{w[index]}"' if quote else str(w[index]) for w in writers]
        return "<<" + ", ".join(cells) + ">>"

    return ("---- MODULE LogRingTraceData ----\n"
            "\\* Generated by scripts/validate_log_ring_trace.py; sequences "
            f"shifted down by {base}.\n"
            "EXTENDS Integers, Sequences\n"
            f"TraceN == {n}\n"
            f"TraceNW == {window.cpus}\n"
            f"TraceMaxSeq == {max_seq}\n"
            f"TraceMargin == {COUNTER_MARGIN}\n"
            f"InitHead == {init['head']}\n"
            f"InitRnext == {init['rnext']}\n"
            f"InitWords == <<{words}>>\n"
            f"InitWord == [s \\in 0 .. TraceN - 1 |-> InitWords[s + 1]]\n"
            f"InitTexts == <<{texts}>>\n"
            f"InitText == [s \\in 0 .. TraceN - 1 |-> InitTexts[s + 1]]\n"
            f"InitWpc == {column(0, True)}\n"
            f"InitWseq == {column(1)}\n"
            f"InitWk == {column(2)}\n"
            f"InitWi == {column(3)}\n"
            "TraceStreams == <<\n  " + ",\n  ".join(streams) + "\n>>\n"
            "Trace == [s \\in 0 .. TraceNW |-> TraceStreams[s + 1]]\n"
            "====\n")


def trace_config(without, model, stop_at):
    constants = dict(FIXED)
    constants.update(model)
    lines = ["SPECIFICATION Spec", "CONSTANTS"]
    lines += [f"  {k} = {'TRUE' if v else 'FALSE'}"
              for k, v in constants.items()]
    lines.append(f'  WITHOUT = "{without or "none"}"')
    lines.append(f"  STOP_AT = {stop_at}")
    for inv in ("NoTornRead", "NoSilentLoss", "NoDoubleOwner",
                "NoNeedlessRefusal", "NotStopped", "TraceUnfinished"):
        lines.append(f"INVARIANT {inv}")
    return "\n".join(lines) + "\n"


def run_tlc(window, without, model, stop_at=0):
    with tempfile.TemporaryDirectory(prefix="takibi-logring-trace.") as work:
        work = Path(work)
        (work / "LogRingTraceData.tla").write_text(trace_module(window),
                                                   encoding="utf-8")
        (work / "LogRingTrace.cfg").write_text(
            trace_config(without, model, stop_at), encoding="utf-8")
        for spec in SPECS:
            (work / spec.name).write_bytes(spec.read_bytes())
        try:
            jar = _PT.tla_jar()
        except _PT.TraceError as error:
            raise TraceError(str(error)) from None
        result = subprocess.run(
            ["java", f"-Djava.io.tmpdir={work}", "-XX:+UseSerialGC",
             "-cp", jar, "tlc2.TLC", "-workers", "1", "-deadlock",
             "-nowarning", "-config", "LogRingTrace.cfg",
             "-metadir", "states", "LogRingTrace.tla"],
            capture_output=True, text=True, check=False, cwd=work)
    return result.stdout + result.stderr


def describe(window, consumed):
    """The next event of each stream after `consumed` (TLC's pos)."""
    lines = []
    for stream, events in sorted(window.streams.items()):
        at = consumed.get(stream, 0)
        name = "reader" if stream == 0 else f"cpu {stream - 1}"
        if at < len(events):
            lines.append(f"    {name}, event {at + 1}: {events[at].line}")
    return "\n".join(lines) or "    (every stream consumed)"


POS_RE = re.compile(r"(\d+) :> (\d+)")


def consumed_of(state):
    """TLC's printed pos, as {stream: count}."""
    text = state.get("pos", "")
    pairs = POS_RE.findall(text)
    if pairs:
        return {int(s): int(c) for s, c in pairs}
    inner = text.strip("<>[] ")
    if inner:
        return {i: int(v) for i, v in enumerate(inner.split(","))}
    return {}


def check(window, without=None, model=None):
    """(errors, counts)."""
    model = model or {}
    base, _ = opening(window)
    shifted = f" (the model's sequences are the kernel's minus {base})"
    output = run_tlc(window, without, model)
    counts = {name: 0 for name in ACTIONS}
    violated = re.search(r"Invariant (\w+) is violated", output)
    if violated and violated.group(1) == "TraceUnfinished":
        for step in _PT.behaviour(output):
            name = step.get("act", "").strip('"')
            if name in counts:
                counts[name] += 1
        return [], counts
    if violated:
        states = _PT.behaviour(output)
        last = states[-1] if states else {}
        act = last.get("act", "?").strip('"')
        tail = "\n".join(f"    {k} = {v}" for k, v in last.items())
        return [f"after {act}, {violated.group(1)} is violated; the next "
                f"events:\n{describe(window, consumed_of(last))}\n"
                f"  the state TLC reached{shifted}:\n{tail}"], counts
    if "Model checking completed. No error has been found." in output:
        depth = re.search(r"depth of the complete state graph search is (\d+)",
                          output)
        reached = int(depth.group(1)) - 1 if depth else 0
        detail = run_tlc(window, without, model, stop_at=reached)
        states = _PT.behaviour(detail)
        last = states[-1] if states else {}
        state = "\n".join(f"    {k} = {v}" for k, v in last.items())
        return [f"no interleaving of the streams is a behaviour of "
                f"LogRing.tla{' without ' + without if without else ''} past "
                f"{reached} event(s); one that reached that far stopped "
                f"before:\n{describe(window, consumed_of(last))}\n"
                f"  the model's state there{shifted}:\n{state}"], counts
    raise TraceError("TLC gave no verdict:\n" + output[-4000:])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("uart_log")
    parser.add_argument("--without", choices=ACTIONS)
    parser.add_argument("--model", action="append", default=[],
                        metavar="NAME=BOOL")
    args = parser.parse_args()
    model = {}
    for item in args.model:
        name, _, flag = item.partition("=")
        if name not in MODEL_CONSTANTS or flag not in ("TRUE", "FALSE"):
            parser.error(f"--model takes one of {', '.join(MODEL_CONSTANTS)}"
                         f"=TRUE|FALSE, not {item}")
        model[name] = flag == "TRUE"
    with open(args.uart_log, encoding="utf-8", errors="replace") as log:
        lines = [line.rstrip("\r\n") for line in log]
    try:
        window = parse(lines)
        errors, counts = check(window, args.without, model)
    except TraceError as error:
        print(f"FAIL log-ring-trace: {error}")
        return 1
    for error in errors:
        print(f"ERROR log-ring-trace: {error}")
    if errors:
        print("FAIL log-ring-trace: the kernel made a ring transition "
              "kernel/models/LogRing.tla does not allow (checked by TLC "
              "through LogRingTrace.tla)")
        return 1
    unseen = [" or ".join(step) for step in REQUIRED
              if args.without not in step
              and not any(counts[name] for name in step)]
    if unseen:
        print("FAIL log-ring-trace: the window never exercised "
              f"{', '.join(unseen)}, so a PASS would say nothing about it")
        return 1
    events = sum(len(es) for es in window.streams.values())
    seen = ", ".join(f"{name}={count}" for name, count in counts.items())
    print(f"PASS log-ring-trace: TLC matched {events} event(s) on "
          f"{window.cpus} cpu(s) and the reader to a behaviour of "
          f"LogRing.tla with its invariants intact ({seen})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
