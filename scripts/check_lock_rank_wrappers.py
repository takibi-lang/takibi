#!/usr/bin/env python3
"""Every kernel function that takes a lock directly carries a lock rank.

GitHub issue #789. SPEC.md's lock-order check sees only functions annotated
`acquires_lock_<rank>_<name>` (and `single_instance_lock` for a lock with one
instance). When #745 moved process records from IntrusivePool to RegionPool,
`process_pool_lock()` became a bare `region_pool_lock_saving` wrapper with no
annotation, and the compiler silently stopped seeing that lock: #672's nested
process-pool acquisition (a self-deadlock) type-checked.

The rule: a kernel function whose body calls `region_pool_lock`,
`region_pool_lock_saving` or `mutex_acquire` declares an
`acquires_lock_<rank>_<name>` effect, or is listed in EXEMPT below with the
reason it needs none. The built-in `region_pool_lock*` carry no rank of their
own, so the wrapper is the only place one can be stated; `mutex_acquire`
carries the generic rank 40 `mutex`, which names no lock class and so cannot
make a single-instance re-acquire an error.

GitHub issue #966 adds the interrupt half. A pool wrapper that takes the
lock WITHOUT masking interrupts (`region_pool_lock`, which saves nothing)
must declare `may_block`: that effect is what makes an `!{interrupt}` root
reaching it a compile error with the call path, and an unmasked lock taken
from a handler on the holder's own core never comes back. A wrapper that
calls `region_pool_lock_saving` must save the mask in the same body
(`mutex_irq_save`), so a saved 0 cannot pass for a masking lock.

Ranks come in two bands, so the compiler's lock-order check is also the
interrupt-safety check Linux's lockdep runs at run time: a lock that does not
mask (it calls `region_pool_lock` or `task_mutex_acquire`) holds a guard
ranked below MASKING_RANK_FLOOR, and a lock that masks (`mutex_irq_save`,
`mutex_acquire`, `region_pool_lock_saving`) holds one ranked at or above it.
Taking an unmasked lock while a masking guard is live is then a lock-order
error. It has to be: a handler interrupting the unmasked holder may spin on
the masking lock, whose holder on another core spins on the unmasked one.

Lexical: comments are stripped, then each `fn` body is brace-matched.
Controls: scripts/check_lock_rank_wrappers_controls.py.
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_only, per_file

ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

ACQUIRE_RE = re.compile(r"\b(region_pool_lock_saving|region_pool_lock|mutex_acquire)\s*\(")
FN_RE = re.compile(r"\bfn\s+([A-Za-z_0-9]+)\s*[(<]")
UNMASKED_RE = re.compile(r"\bregion_pool_lock\s*\(")
SAVING_RE = re.compile(r"\bregion_pool_lock_saving\s*\(")
MASK_SAVE_RE = re.compile(r"\bmutex_irq_save\s*\(")
MAY_BLOCK_RE = re.compile(r"\bmay_block\b")
GUARD_RANK_RE = re.compile(r"\block_guard_([0-9]+)_[A-Za-z_0-9]+\b")
UNMASKED_TAKE_RE = re.compile(r"\b(region_pool_lock|task_mutex_acquire)\s*\(")
MASKED_TAKE_RE = re.compile(r"\b(mutex_irq_save|mutex_acquire|region_pool_lock_saving)\s*\(")
MASKING_RANK_FLOOR = 40
RANK_RE = re.compile(r"\bacquires_lock_[0-9]+_[A-Za-z_0-9]+\b")

# function name -> why it needs no rank of its own. Reviewed entries only.
# None today: every lock-taking kernel function states its rank.
EXEMPT: dict = {}


# Shared with every code-property check: blanks `//` and `/* */` comments,
# keeps string literals (GitHub issue #815).
strip_comments = code_only


def body_start(text: str, index: int):
    """Index of the `{` opening the body of the fn whose name ends at index,
    or None for a bodiless declaration. A `{` after `!` (effect row), after
    `->` or `:` (refinement type), or inside brackets is not the body."""
    depth = 0
    while index < len(text):
        ch = text[index]
        if ch in "([<" and not (ch == "<" and text[index - 1] == "-"):
            depth += 1
        elif ch in ")]>" and not (ch == ">" and text[index - 1] == "-"):
            depth -= 1
        elif ch == "{":
            # The text before this `{`, without copying it: the last
            # non-blank character(s) decide whether it opens the body.
            back = index - 1
            while back >= 0 and text[back].isspace():
                back -= 1
            tail = text[max(0, back - 1):back + 1]
            if depth == 0 and not tail.endswith(("!", "->", ":", ",")):
                return index
            close = index
            inner = 0
            for close in range(index, len(text)):
                if text[close] == "{":
                    inner += 1
                elif text[close] == "}":
                    inner -= 1
                    if inner == 0:
                        break
            index = close
        elif ch == ";" and depth == 0:
            return None
        index += 1
    return None


def functions(text: str):
    """Yield (name, header, body) for each fn with a body."""
    text = strip_comments(text)
    for match in FN_RE.finditer(text):
        body = body_start(text, match.end() - 1)
        if body is None:
            continue
        header = text[match.start():body]
        depth = 0
        for index in range(body, len(text)):
            ch = text[index]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    break
        yield match.group(1), header, text[body:index + 1]


@per_file
def file_scan(text: str):
    """(lock-taking names, unranked (name, calls) pairs) of one file. Cached
    by content: the controls change one file at a time, so every other file
    is scanned once (#804 follow-up: the uncached controls re-parsed the
    whole kernel per case and overran the fast gate's 10 s bound)."""
    takers = []
    unranked = []
    unmasked = []
    for name, header, body in functions(text):
        if UNMASKED_RE.search(body) and not MAY_BLOCK_RE.search(header):
            unmasked.append((name, "calls region_pool_lock, which does not mask "
                             "interrupts, but declares no may_block (#966: without it an "
                             "!{interrupt} root may reach this lock unchecked)"))
        for rank in (int(r) for r in GUARD_RANK_RE.findall(header)):
            if UNMASKED_TAKE_RE.search(body) and rank >= MASKING_RANK_FLOOR:
                unmasked.append((name, f"holds an unmasked lock at guard rank {rank}; "
                                 f"unmasked locks rank below {MASKING_RANK_FLOOR} (#966)"))
            elif MASKED_TAKE_RE.search(body) and rank < MASKING_RANK_FLOOR:
                unmasked.append((name, f"holds a masking lock at guard rank {rank}; "
                                 f"masking locks rank {MASKING_RANK_FLOOR} or above (#966)"))
        if SAVING_RE.search(body) and not MASK_SAVE_RE.search(body):
            unmasked.append((name, "calls region_pool_lock_saving without mutex_irq_save "
                             "in the same body (#966: use region_pool_lock and may_block "
                             "for a lock that does not mask)"))
        calls = sorted(set(m.group(1) for m in ACQUIRE_RE.finditer(body)))
        if calls:
            takers.append(name)
            if not RANK_RE.search(header):
                unranked.append((name, tuple(calls)))
    return tuple(takers), tuple(unranked), tuple(unmasked)


def problems(sources: dict, exempt: dict = EXEMPT) -> list:
    found = []
    takers = set()
    for path, text in sorted(sources.items()):
        file_takers, unranked, unmasked = file_scan(text)
        for name, why in unmasked:
            found.append(f"{path}: fn {name} {why}")
        takers.update(file_takers)
        for name, calls in unranked:
            if name in exempt:
                continue
            found.append(f"{path}: fn {name} calls {', '.join(calls)} but declares no "
                         f"acquires_lock_<rank>_<name> (add one, with single_instance_lock "
                         f"if the lock has one instance, or a reviewed EXEMPT entry)")
    for name in sorted(set(exempt) - takers):
        found.append(f"EXEMPT entry {name} names no lock-taking kernel function; drop it")
    return found


def kernel_sources() -> dict:
    return {str(path.relative_to(ROOT)): path.read_text()
            for path in sorted(KERNEL.rglob("*.tkb")) if "build" not in path.parts}


def main() -> int:
    sources = kernel_sources()
    found = problems(sources)
    for line in found:
        print("FAIL lock-rank-wrappers: " + line, file=sys.stderr)
    if found:
        return 1
    wrappers = sum(1 for text in sources.values() for _, _, body in functions(text)
                   if ACQUIRE_RE.search(body))
    report_pass("lock-rank-wrappers",
                f"{wrappers} lock-taking functions in {len(sources)} files carry a rank "
                f"({len(EXEMPT)} exempt)", wrappers=wrappers)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
