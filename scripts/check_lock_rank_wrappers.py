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

Lexical: comments are stripped, then each `fn` body is brace-matched.
Controls: scripts/check_lock_rank_wrappers_controls.py.
"""

import functools
import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

ACQUIRE_RE = re.compile(r"\b(region_pool_lock_saving|region_pool_lock|mutex_acquire)\s*\(")
FN_RE = re.compile(r"\bfn\s+([A-Za-z_0-9]+)\s*[(<]")
RANK_RE = re.compile(r"\bacquires_lock_[0-9]+_[A-Za-z_0-9]+\b")

# function name -> why it needs no rank of its own. Reviewed entries only.
# None today: every lock-taking kernel function states its rank.
EXEMPT: dict = {}


def strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


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


@functools.lru_cache(maxsize=None)
def file_scan(text: str):
    """(lock-taking names, unranked (name, calls) pairs) of one file. Cached
    by content: the controls change one file at a time, so every other file
    is scanned once (#804 follow-up: the uncached controls re-parsed the
    whole kernel per case and overran the fast gate's 10 s bound)."""
    takers = []
    unranked = []
    for name, header, body in functions(text):
        calls = sorted(set(m.group(1) for m in ACQUIRE_RE.finditer(body)))
        if calls:
            takers.append(name)
            if not RANK_RE.search(header):
                unranked.append((name, tuple(calls)))
    return tuple(takers), tuple(unranked)


def problems(sources: dict, exempt: dict = EXEMPT) -> list:
    found = []
    takers = set()
    for path, text in sorted(sources.items()):
        file_takers, unranked = file_scan(text)
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
