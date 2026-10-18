#!/usr/bin/env python3
"""The herdtools7 pin is the same in the devcontainer and in CI (#645).

herd7 checks the litmus tests in `make modelcheck`. It comes from opam,
installed by .devcontainer/devcontainer.json's postCreateCommand for
development sessions and by .github/workflows/ci.yml for CI. Two pins can
drift silently: a local pass would then say nothing about CI's verdict, since
a herd7 release can change the AArch64 model. Each file must name exactly one
`herdtools7.<version>`, and the two must agree.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

DEVCONTAINER = pathlib.Path(".devcontainer/devcontainer.json")
CI = pathlib.Path(".github/workflows/ci.yml")
PIN = re.compile(r"\bherdtools7\.(\d+(?:\.\d+)+)\b")


def problems(texts: dict) -> tuple:
    found = []
    pins = {}
    for name, text in sorted(texts.items()):
        versions = sorted(set(PIN.findall(text)))
        if len(versions) != 1:
            found.append(f"{name} names herdtools7 versions {versions or 'none'}; "
                         "it must pin exactly one (herdtools7.<version>)")
        else:
            pins[name] = versions[0]
    if len(set(pins.values())) > 1:
        found.append("herdtools7 pins differ: " +
                     ", ".join(f"{n}={v}" for n, v in sorted(pins.items())))
    return tuple(found)


def tree_texts() -> dict:
    return {str(p): p.read_text(encoding="ascii") for p in (DEVCONTAINER, CI)}


def main() -> int:
    texts = tree_texts()
    found = problems(texts)
    if found:
        for line in found:
            print(f"FAIL herdtools-pin: {line}")
        return 1
    version = PIN.search(texts[str(CI)]).group(1)
    report_pass("herdtools-pin",
                f"devcontainer and CI both pin herdtools7 {version}",
                files=len(texts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
