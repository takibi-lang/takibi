#!/usr/bin/env python3
"""GitHub issue #899 (from #756): no count wait runs on one peer's clock alone.

A peer_tick_window is bounded by ONE core's timer ticks. #756's shape was
one window on CPU 1's ticks around a wait for a count every peer adds to:
CPU 1 ticked, its window closed, and the wait timed out for a later peer
that was still masked and had not arrived. #860 settled the accepted forms:

  * the wait reads only a word of the window's own peer (`x[cpu]` under a
    window on `cpu`), or
  * the window is opened per peer inside a `for cpu ... ..<KERNEL_MAX_CORES`
    loop, so every peer's own budget is spent before the wait gives up, or
  * a `peer-window-ok:` comment just above the window says why that clock
    bounds the wait (a single writer, or any-of rather than all-of).

Every `peer_tick_window_policy` window in kernel/**/*.tkb whose loop reads
an atomic word is checked against those forms; reads of an `armed` word
are a stop flag, not the awaited count, and are skipped. Lexical: a count
read through a helper call is not seen. Planted texts are refused.
"""
import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
OPEN_RE = re.compile(r"let mut (\w+) = peer_tick_window_policy\(\s*([^,]+?)\s*,")
FOR_PEERS_RE = re.compile(r"for (\w+): usize in \d+\.\.<KERNEL_MAX_CORES")
LOAD_RE = re.compile(r"atomic_word_load\(([^()]*(?:\([^()]*\))?[^()]*)\)")


def windows(text: str) -> list[tuple[int, str]]:
    """(line, error) for each window that breaks the rule."""
    lines = text.splitlines()
    errors = []
    joined = "\n".join(lines)
    for match in OPEN_RE.finditer(joined):
        name, peer = match.group(1), match.group(2).strip()
        line_no = joined.count("\n", 0, match.start()) + 1
        end = joined.find(f"peer_tick_window_end({name})", match.end())
        if end < 0:
            continue
        region = joined[match.end():end]
        loads = [l for l in LOAD_RE.findall(region) if "armed" not in l]
        if not loads:
            continue
        before = lines[max(0, line_no - 4):line_no - 1]
        if any("peer-window-ok:" in l for l in before):
            continue
        if all(f"[{peer}]" in l for l in loads):
            continue
        enclosing = lines[max(0, line_no - 6):line_no - 1]
        if any((m := FOR_PEERS_RE.search(l)) and m.group(1) == peer for l in enclosing):
            continue
        errors.append((line_no, f"window `{name}` on `{peer}` waits on "
                       f"{', '.join(sorted(set(loads)))}: not that peer's word, not inside a "
                       f"per-peer loop, and no peer-window-ok: reason"))
    return errors


def controls() -> int:
    bad = ("let mut w = peer_tick_window_policy(1, P::Arrival);\n"
           "while (peer_tick_window_open(w) && atomic_word_load(&count) < online) { }\n"
           "peer_tick_window_end(w);\n")
    good_loop = ("for cpu: usize in 1..<KERNEL_MAX_CORES {\n  if (cpu < online) {\n"
                 "let mut w = peer_tick_window_policy(cpu, P::Arrival);\n"
                 "while (peer_tick_window_open(w) && atomic_word_load(&count) < online) { }\n"
                 "peer_tick_window_end(w);\n")
    good_own = ("let mut w = peer_tick_window_policy(peer, P::Arrival);\n"
                "while (peer_tick_window_open(w) && atomic_word_load(&t.count[peer]) < n) { }\n"
                "peer_tick_window_end(w);\n")
    good_reason = "// peer-window-ok: core 0 alone stores go\n" + bad
    assert windows(bad), "a single window over an aggregate count passed"
    for text in (good_loop, good_own, good_reason):
        assert not windows(text), f"an accepted form was refused: {text!r}"
    return 4


def main() -> int:
    planted = controls()
    errors = []
    checked = 0
    for path in sorted((ROOT / "kernel").rglob("*.tkb")):
        text = path.read_text(encoding="ascii", errors="replace")
        if "peer_tick_window_policy(" not in text:
            continue
        checked += text.count("peer_tick_window_policy(")
        for line_no, error in windows(text):
            errors.append(f"{path.relative_to(ROOT)}:{line_no}: {error}")
    if errors:
        for error in errors:
            print(f"FAIL  {error}")
        return 1
    report_pass("probe-aggregate-wait",
                f"{checked} peer windows wait only on their peer's word, per peer, "
                f"or carry a peer-window-ok: reason; {planted} planted texts judged",
                windows=checked, planted=planted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
