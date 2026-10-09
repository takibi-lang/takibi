#!/usr/bin/env python3
"""Refuse every legacy receive cache operation in the maintained kernel.

The fixed-allocation compiler rule protects only allocations declared with
`dma_fixed`. A legacy dma_prepare_rx/dma_finish_rx call would silently
restore the unpaired prepare/finish class that prompted issue #596. GEM's
receive buffer, the last user, became a fixed allocation in issue #622, so
no such call is allowed anywhere now.
"""

from pathlib import Path
import re
import sys

from pass_line import report_pass

CALL = re.compile(r"\bdma_(?:prepare_rx|finish_rx)\s*\(")
GEM = Path("kernel/drivers/net/rp1_gem.tkb")
# Empty since issue #622; a future audited exception would be listed here
# with its expected count.
ALLOWED: dict[str, int] = {}


def code_only(source: str) -> str:
    """Blank comments and strings without hiding code after a quoted `//`."""
    result = list(source)
    state = "code"
    index = 0
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if char == '"':
                state = "string"
                result[index] = " "
            elif char == "/" and next_char in ("/", "*"):
                state = "line" if next_char == "/" else "block"
                result[index] = result[index + 1] = " "
                index += 1
        elif state == "string":
            if char == "\\" and next_char:
                result[index] = result[index + 1] = " "
                index += 1
            else:
                if char == '"':
                    state = "code"
                if char != "\n":
                    result[index] = " "
        elif state == "line":
            if char == "\n":
                state = "code"
            else:
                result[index] = " "
        else:
            if char == "*" and next_char == "/":
                state = "code"
                result[index] = result[index + 1] = " "
                index += 1
            elif char != "\n":
                result[index] = " "
        index += 1
    return "".join(result)


def audit(sources: dict[Path, str]) -> tuple[list[str], int]:
    failures: list[str] = []
    found: dict[str, int] = {}
    calls = 0
    for path, source in sorted(sources.items()):
        # code_only only blanks characters, so it cannot create a callee name
        # the raw text lacks; a file without either name has no call. Not
        # CALL itself: blanking a comment between a name and its `(` can
        # create a match the raw text does not have. Skipping the per-char
        # scan of every other file is what keeps this inside the fast gate's
        # bound on a loaded host (#703).
        if "dma_prepare_rx" not in source and "dma_finish_rx" not in source:
            continue
        code = code_only(source)
        for match in CALL.finditer(code):
            calls += 1
            end = code.find(")", match.end())
            if end < 0:
                failures.append(f"{path}: unterminated legacy RX call")
                continue
            spelling = re.sub(r"\s+", "", code[match.start():end + 1])
            allowed = {re.sub(r"\s+", "", key): key for key in ALLOWED}
            if path != GEM or spelling not in allowed:
                failures.append(f"{path}: legacy RX call {spelling}: use a dma_fixed allocation")
            else:
                key = allowed[spelling]
                found[key] = found.get(key, 0) + 1
    for spelling, expected in ALLOWED.items():
        if found.get(spelling, 0) != expected:
            failures.append(f"{GEM}: expected {expected} call(s) to {spelling}, found {found.get(spelling, 0)}")
    return failures, calls


def main() -> int:
    paths = sorted(Path("kernel").rglob("*.tkb"))
    if not paths:
        print("FAIL legacy-dma-rx: no maintained kernel sources found", file=sys.stderr)
        return 1
    failures, calls = audit({path: path.read_text(encoding="ascii") for path in paths})
    if failures:
        for failure in failures:
            print("FAIL legacy-dma-rx: " + failure, file=sys.stderr)
        return 1
    report_pass("legacy-dma-rx",
                f"no legacy RX cache call in {len(paths)} maintained kernel files",
                # The call count is legitimately zero; the files scanned are
                # what must not be.
                files=len(paths))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
