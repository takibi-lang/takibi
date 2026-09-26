#!/usr/bin/env python3
"""Every kernel function a TLA+ model claims to abstract still exists.

GitHub issue #601. kernel/models/README.md maps each model action to the
Takibi functions it abstracts. The model and the code are never compiled
together, so a renamed or removed function would leave a row that points at
nothing and a model nobody knows to re-read. This check reads every
backquoted `kernel_*` / `scheduled_process_*` name in the table rows and
fails if no `fn <name>` definition exists under kernel/.

It catches a rename or a removal. It does NOT catch a change of behaviour
inside a function that still has its name; that is the review's job, and the
README records the proposal for catching it too.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
README = ROOT / "kernel" / "models" / "README.md"
NAME_RE = re.compile(r"`((?:kernel|scheduled_process)_[a-z0-9_]+)`")


def mapped_names(text: str) -> list[str]:
    names = []
    for line in text.splitlines():
        if line.startswith("| `"):
            names.extend(NAME_RE.findall(line))
    return names


def missing(names: list[str], sources: str) -> list[str]:
    return [name for name in names
            if not re.search(rf"^(?:private )?fn {name}\b", sources, re.M)]


def main() -> int:
    names = mapped_names(README.read_text(encoding="utf-8"))
    if not names:
        print("FAIL model-function-map: kernel/models/README.md maps no "
              "function, so this check would pass about nothing")
        return 1
    sources = "\n".join(path.read_text(encoding="utf-8")
                        for path in sorted((ROOT / "kernel").rglob("*.tkb")))
    gone = missing(names, sources)
    for name in gone:
        print(f"ERROR model-function-map: kernel/models/README.md maps an "
              f"action to {name}, which no kernel .tkb file defines. Update "
              f"the row, and re-read the model's action against the code "
              f"that replaced it")
    if gone:
        print("FAIL model-function-map: a model row points at a function "
              "that no longer exists")
        return 1
    # Negative control: a name that cannot exist must be reported.
    if not missing(["kernel_model_map_control_absent"], sources):
        print("FAIL model-function-map: an absent function was not reported, "
              "so this check proves nothing")
        return 1
    report_pass(
        "model-function-map",
        f"{len(names)} kernel function name(s) mapped by the TLA+ models "
        "exist, and an absent name is refused",
        mapped_functions=len(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
