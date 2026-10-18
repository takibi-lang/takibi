#!/usr/bin/env python3
"""herd7: one pin, and CI builds it only behind its cache (#645).

herd7 checks the litmus tests in `make modelcheck`. Development sessions get
it from opam (.devcontainer/devcontainer.json's postCreateCommand); CI builds
it with scripts/build_herd7.sh, which holds CI's pin. Two pins can drift
silently: a local pass would then say nothing about CI's verdict, since a
herd7 release can change the AArch64 model. Each of the two files must name
exactly one `herdtools7.<version>`, and the two must agree.

The CI shape is checked too, because the first one broke main: `opam install
herdtools7` in the job's in-checkout switch failed (herdtools7's dune walked
up to takibi's dune-project) and would rebuild it on every run. So
.github/workflows/ci.yml must

  - name herdtools7 in no `opam` command;
  - run scripts/build_herd7.sh in exactly one step, guarded by
    `if: steps.herd7-cache.outputs.cache-hit != 'true'`;
  - have the step `id: herd7-cache` whose key hashes scripts/build_herd7.sh
    (the key then changes with the pin) and whose path is the build's DEST;
  - point HERD7 at DEST/bin/herd7.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import per_file

DEVCONTAINER = pathlib.Path(".devcontainer/devcontainer.json")
BUILD = pathlib.Path("scripts/build_herd7.sh")
CI = pathlib.Path(".github/workflows/ci.yml")
PIN = re.compile(r"\bherdtools7\.(\d+(?:\.\d+)+)\b")
STEP = re.compile(r"^      - ", re.M)
GUARD = "if: steps.herd7-cache.outputs.cache-hit != 'true'"
KEY = "hashFiles('scripts/build_herd7.sh')"


@per_file
def pinned_versions(text: str) -> tuple:
    return tuple(sorted(set(PIN.findall(text))))


def ci_problems(text: str) -> list:
    found = []
    for line in text.splitlines():
        if "opam" in line and "herdtools7" in line and not line.lstrip().startswith("#"):
            found.append(f"{CI} installs herdtools7 through opam: {line.strip()!r}; "
                         f"CI builds herd7 only with {BUILD} behind its cache")
    steps = STEP.split(text)[1:]
    builds = [s for s in steps if any(
        f"bash {BUILD}" in l and not l.lstrip().startswith("#") for l in s.splitlines())]
    caches = [s for s in steps if re.search(r"^\s*id: herd7-cache\s*$", s, re.M)]
    if len(builds) != 1:
        found.append(f"{CI} runs {BUILD} in {len(builds)} steps; it must be exactly one")
    elif GUARD not in builds[0]:
        found.append(f"{CI}'s {BUILD} step lacks `{GUARD}`; it would build every run")
    if len(caches) != 1:
        found.append(f"{CI} has {len(caches)} steps with id herd7-cache; it must be one")
        return found
    cache = caches[0]
    if KEY not in cache:
        found.append(f"{CI}'s herd7-cache key does not hash {BUILD}; a pin bump would reuse the old herd7")
    path = re.search(r"^\s*path: (\S+)\s*$", cache, re.M)
    if not path:
        found.append(f"{CI}'s herd7-cache step names no single path")
        return found
    dest = path.group(1)
    if builds and not re.search(rf"{re.escape(str(BUILD))} {re.escape(dest)}\s*$",
                                builds[0], re.M):
        found.append(f"{CI}'s {BUILD} step does not build into the cached path {dest}")
    if not re.search(rf"^\s*HERD7: {re.escape(dest)}/bin/herd7\s*$", text, re.M):
        found.append(f"{CI} does not set HERD7: {dest}/bin/herd7 for make")
    return found


def problems(texts: dict) -> tuple:
    found = []
    pins = {}
    for name in (str(DEVCONTAINER), str(BUILD)):
        versions = list(pinned_versions(texts[name]))
        if len(versions) != 1:
            found.append(f"{name} names herdtools7 versions {versions or 'none'}; "
                         "it must pin exactly one (herdtools7.<version>)")
        else:
            pins[name] = versions[0]
    if len(set(pins.values())) > 1:
        found.append("herdtools7 pins differ: " +
                     ", ".join(f"{n}={v}" for n, v in sorted(pins.items())))
    found.extend(ci_problems(texts[str(CI)]))
    return tuple(found)


def tree_texts() -> dict:
    return {str(p): p.read_text(encoding="ascii") for p in (DEVCONTAINER, BUILD, CI)}


def main() -> int:
    texts = tree_texts()
    found = problems(texts)
    if found:
        for line in found:
            print(f"FAIL herdtools-pin: {line}")
        return 1
    version = PIN.search(texts[str(BUILD)]).group(1)
    report_pass("herdtools-pin",
                f"devcontainer and CI both pin herdtools7 {version}; "
                "CI builds it only on a herd7 cache miss",
                files=len(texts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
