#!/usr/bin/env python3
"""GitHub issue #1355: every package the Makefile downloads is pinned.

Alpine keeps only a branch's latest package revision, so a pinned
revision's URL can 404 one day, or a URL can start serving other bytes.
Nothing noticed until a clean build failed. This check refuses:

  * a `curl` recipe line in the Makefile outside `define fetch_pinned`,
    the one fetch that verifies a sha256 before a rule can use the file;
  * a `*_URL` variable with no `*_SHA256` partner of 64 hex digits.

A planted Makefile with one of each is refused too, so the check cannot
pass by matching nothing.
"""
import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent

URL_RE = re.compile(r"^([A-Z0-9_]+)_URL\s*:?=\s*\S", re.M)
SHA_RE = re.compile(r"^([A-Z0-9_]+)_SHA256\s*:?=\s*([0-9a-f]{64})\s*$", re.M)


def problems(text: str) -> list[str]:
    found: list[str] = []
    in_macro = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("define fetch_pinned"):
            in_macro = True
            continue
        if in_macro and line.startswith("endef"):
            in_macro = False
            continue
        if not in_macro and line.startswith("\t") and re.search(r"\bcurl\b", line):
            found.append(f"line {number}: curl outside fetch_pinned")
    pinned = {match.group(1) for match in SHA_RE.finditer(text)}
    for match in URL_RE.finditer(text):
        if match.group(1) not in pinned:
            found.append(f"{match.group(1)}_URL has no {match.group(1)}_SHA256")
    return found


def main() -> int:
    text = (ROOT / "Makefile").read_text()
    found = problems(text)
    if found:
        for item in found:
            print(f"FAIL pinned-downloads: Makefile {item}", file=sys.stderr)
        return 1
    planted = "X_URL := https://example.invalid/x.apk\n$(X):\n\tcurl -o $@ $(X_URL)\n"
    if len(problems(planted)) != 2:
        print("FAIL pinned-downloads: the planted control was not refused", file=sys.stderr)
        return 1
    report_pass("pinned-downloads",
                f"{len(URL_RE.findall(text))} downloaded package(s), each "
                "fetched through fetch_pinned with a sha256; a planted "
                "unpinned one is refused",
                packages=len(URL_RE.findall(text)),
                pins=len(SHA_RE.findall(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
