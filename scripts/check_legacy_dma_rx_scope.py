#!/usr/bin/env python3
"""Keep legacy receive cache operations within the audited GEM data path.

The fixed-allocation compiler rule protects only allocations declared with
`dma_fixed`. A new legacy RX call in another maintained driver would silently
restore the unpaired prepare/finish class that prompted issue #596. This check
does not prove GEM's own ownership protocol; issue #622 owns that migration.
"""

from pathlib import Path
import re
import sys

from pass_line import report_pass

CALL = re.compile(r"\bdma_(?:prepare_rx|finish_rx)\s*\(")
GEM = Path("kernel/drivers/net/rp1_gem.tkb")
ALLOWED = {
    "dma_prepare_rx(gem_rx_buf, RX_BUF_SIZE)": 2,
    "dma_finish_rx(gem_rx_buf, RX_BUF_SIZE)": 1,
}


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
                failures.append(f"{path}: legacy RX call {spelling} is outside the audited GEM buffer")
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
                f"{calls} audited legacy GEM RX call(s); no other maintained RX cache calls",
                files=len(paths), calls=calls)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
