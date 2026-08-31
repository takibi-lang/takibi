#!/usr/bin/env python3
"""Lexical controls for the trusted-base unsafe-block inventory."""

import tempfile
from pathlib import Path

from measure_trusted_base import unsafe_blocks


def scan(source: str) -> list[tuple[int, str]]:
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "control.tkb"
        path.write_text(source, encoding="ascii")
        return unsafe_blocks(path)


fake_only = scan(
    "// unsafe { fake as *io u32 }\n"
    "/* unsafe { fake as *u8 } and a spare } */\n"
    "let text = \"unsafe { fake as *u8 }\\\" still text\";\n"
    "let open_brace: u8 = '{';\n"
    "let close_brace: u8 = '}';\n"
)
if fake_only:
    raise SystemExit(f"comment/literal-only control reported {len(fake_only)} sites")

real = scan(
    "fn controls() {\n"
    "  let first = unsafe { 1 as *u8 };\n"
    "  let second = unsafe /* trivia between keyword and brace */\n"
    "  {\n"
    "    let text = \"escaped quote \\\" and closing brace }\";\n"
    "    /* neither } nor unsafe { changes the real depth */\n"
    "    if (true) { let byte: u8 = '}'; }\n"
    "    2 as *u8\n"
    "  };\n"
    "}\n"
)
if [line for line, _ in real] != [2, 3]:
    raise SystemExit(f"real unsafe controls have wrong start lines: {real!r}")
if "2 as *u8" not in real[1][1]:
    raise SystemExit("comment/literal brace ended a real unsafe block early")

try:
    scan("fn broken() { let pointer = unsafe { 1 as *u8;\n")
except SystemExit as error:
    if "unterminated unsafe block" not in str(error):
        raise SystemExit(f"unterminated control had wrong diagnostic: {error}")
else:
    raise SystemExit("unterminated real unsafe block unexpectedly passed")

print("PASS trusted-base lexical controls")
