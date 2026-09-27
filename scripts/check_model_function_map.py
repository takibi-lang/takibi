#!/usr/bin/env python3
"""The TLA+ action tables still point at real code and justify every drop.

GitHub issues #601 and #616. kernel/models/README.md maps each model action
to the Takibi functions it abstracts, and says what the action keeps and
what it drops. The model and the code are never compiled together, so this
check is what ties the table to both:

- every backquoted `kernel_*` / `scheduled_process_*` name in a row has an
  `fn <name>` definition under kernel/, and every action a row names is
  defined in the section's .tla;
- every "dropped" cell is `nothing`, or `; `-separated entries of the form
  `<path> -- <why>`, where <why> is one of
    modelled elsewhere: `Model.Action` (or `Action` in the same model),
        and that .tla defines the action;
    guarded: `<function>` fail-stops with `<activity>`, where the function
        sets the KernelActivity variant that kernel_activity_name names so;
    irrelevant to `<Property>`: <reason>, where the section's .tla defines
        the property.

#609's defect sat in a path StackOwnership.tla listed as dropped with no
reason, which is why a bare "X is dropped" is refused.

It catches a rename, a removal, and an unjustified drop. It does NOT catch a
change of behaviour inside a function that keeps its name; that is the
review's job.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODELS = ROOT / "kernel" / "models"
README = MODELS / "README.md"
NAME_RE = re.compile(r"`((?:kernel|scheduled_process)_[a-z0-9_]+)`")
SECTION_RE = re.compile(r"^## (\w+)\.tla\b")
ACTION_RE = re.compile(r"`(\w+)`")
ELSEWHERE_RE = re.compile(r"^modelled elsewhere: `(?:(\w+)\.)?(\w+)`$")
GUARDED_RE = re.compile(r"^guarded: `(\w+)` fail-stops with `([a-z0-9-]+)`$")
IRRELEVANT_RE = re.compile(r"^irrelevant to `(\w+)`: \S.*$")
ACTIVITY_RE = re.compile(
    r'KernelActivity::(\w+)\s*=>\s*\{\s*return\s*"([a-z0-9-]+)"')


def table_rows(text: str) -> list[tuple[str, list[str]]]:
    """(model, cells) for every action row, model from the section heading."""
    rows = []
    model = None
    for line in text.splitlines():
        heading = SECTION_RE.match(line)
        if heading:
            model = heading.group(1)
        elif line.startswith("| `") and model:
            rows.append((model, [c.strip() for c in line.strip("|").split("|")]))
    return rows


def defined_names(tla: str) -> set[str]:
    return set(re.findall(r"^(\w+)(?:\([^)]*\))?\s*==", tla, re.M))


def function_body(name: str, sources: str) -> str | None:
    match = re.search(rf"^(?:private )?fn {name}\b.*?^}}", sources,
                      re.M | re.S)
    return match.group(0) if match else None


def missing(names: list[str], sources: str) -> list[str]:
    return [name for name in names if function_body(name, sources) is None]


def dropped_errors(model: str, cell: str, tla_defs: dict[str, set[str]],
                   sources: str) -> list[str]:
    """Why a dropped cell is not justified; empty when it is."""
    if cell == "nothing":
        return []
    errors = []
    activities = {text: variant
                  for variant, text in ACTIVITY_RE.findall(sources)}
    for entry in cell.split("; "):
        path, sep, why = entry.partition(" -- ")
        if not sep or not path:
            errors.append(f"'{entry}' has no '<path> -- <why>' form")
            continue
        if match := ELSEWHERE_RE.match(why):
            other = match.group(1) or model
            if match.group(2) not in tla_defs.get(other, set()):
                errors.append(f"'{path}' is modelled elsewhere in "
                              f"{other}.{match.group(2)}, which no "
                              f"kernel/models/{other}.tla defines")
        elif match := GUARDED_RE.match(why):
            function, activity = match.groups()
            body = function_body(function, sources)
            variant = activities.get(activity)
            if body is None:
                errors.append(f"'{path}' is guarded by {function}, which no "
                              "kernel .tkb file defines")
            elif variant is None:
                errors.append(f"'{path}' is guarded by activity {activity}, "
                              "which kernel_activity_name never returns")
            elif f"kernel_activity_set(KernelActivity::{variant})" not in body:
                errors.append(f"'{path}' is guarded by {function}, which "
                              f"never sets KernelActivity::{variant}")
        elif match := IRRELEVANT_RE.match(why):
            if match.group(1) not in tla_defs.get(model, set()):
                errors.append(f"'{path}' is irrelevant to {match.group(1)}, "
                              f"which {model}.tla does not define")
        else:
            errors.append(f"'{path}' says neither 'modelled elsewhere', "
                          "'guarded' nor 'irrelevant to'")
    return errors


def row_errors(model: str, cells: list[str], tla_defs: dict[str, set[str]],
               sources: str) -> list[str]:
    if len(cells) != 4:
        return [f"{cells[0]} has {len(cells)} cells, not 4"]
    errors = [f"{model}.tla does not define action {action}"
              for action in ACTION_RE.findall(cells[0])
              if action not in tla_defs.get(model, set())]
    errors += [f"{cells[0]} maps to {name}, which no kernel .tkb file "
               "defines; update the row and re-read the model's action "
               "against the code that replaced it"
               for name in missing(NAME_RE.findall(cells[1]), sources)]
    errors += dropped_errors(model, cells[3], tla_defs, sources)
    return errors


def controls_fail(tla_defs: dict[str, set[str]], sources: str) -> list[str]:
    """Rows that must be refused; a name for each one that is not."""
    refused = {
        "absent function": ["`Dispatch`", "`kernel_model_map_control_absent`",
                            "x", "nothing"],
        "bare drop": ["`Dispatch`", "`kernel_process_secondary_start`", "x",
                      "affinity is dropped"],
        "absent action": ["`Dispatch`", "`kernel_process_secondary_start`",
                          "x", "a -- modelled elsewhere: `Wait4Block.Absent`"],
        "absent activity": ["`Dispatch`", "`kernel_process_secondary_start`",
                            "x", "a -- guarded: `scheduled_process_start` "
                            "fail-stops with `control-absent`"],
        "guard elsewhere": ["`Dispatch`", "`kernel_process_secondary_start`",
                            "x", "a -- guarded: `scheduled_process_start` "
                            "fail-stops with `reap-on-owned-stack`"],
        "absent property": ["`Dispatch`", "`kernel_process_secondary_start`",
                            "x", "a -- irrelevant to `ControlAbsent`: no"],
    }
    return [name for name, cells in refused.items()
            if not row_errors("StackOwnership", cells, tla_defs, sources)]


def main() -> int:
    rows = table_rows(README.read_text(encoding="utf-8"))
    tla_defs = {path.stem: defined_names(path.read_text(encoding="utf-8"))
                for path in MODELS.glob("*.tla")}
    sources = "\n".join(path.read_text(encoding="utf-8")
                        for path in sorted((ROOT / "kernel").rglob("*.tkb")))
    failed = False
    for model, cells in rows:
        for error in row_errors(model, cells, tla_defs, sources):
            print(f"ERROR model-function-map: kernel/models/README.md "
                  f"{model}: {error}")
            failed = True
    if failed:
        print("FAIL model-function-map: an action row points at nothing or "
              "drops a path without saying why that is safe")
        return 1
    if not_refused := controls_fail(tla_defs, sources):
        print("FAIL model-function-map: negative control(s) "
              f"{', '.join(not_refused)} were not refused, so this check "
              "proves nothing")
        return 1
    drops = sum(len(cells[3].split("; ")) for _, cells in rows
                if len(cells) == 4 and cells[3] != "nothing")
    report_pass(
        "model-function-map",
        f"{len(rows)} action row(s) name existing actions and functions, "
        f"{drops} dropped path(s) are each justified, and an unjustified "
        "row is refused",
        action_rows=len(rows),
        dropped_paths=drops,
        models=len({model for model, _ in rows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
