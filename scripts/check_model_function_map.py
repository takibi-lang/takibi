#!/usr/bin/env python3
"""The TLA+ action tables still point at real code and justify every drop.

GitHub issues #601, #616 and #617. kernel/models/README.md maps each model action
to the Takibi functions it abstracts, and says what the action keeps and
what it drops. The model and the code are never compiled together, so this
check is what ties the table to both:

- every backquoted `kernel_*` / `scheduled_process_*` / DMA driver name in a row has an
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

- every row's "reviewed" cell is a hash of the bodies of the functions it
  maps and of the guards its dropped paths name, comments and whitespace
  stripped. A change to any of them fails
  until a reviewer re-reads the row against the model and restamps it:

      python3 scripts/check_model_function_map.py --restamp

  The commit that restamps says what was reviewed. #609 changed
  kernel_process_child_exit in a way that mattered to StackOwnership.tla,
  and nothing asked for the model to be looked at.

The hash says only "look again", not what is wrong, and it fires whether or
not any test exercises the change.

Exit code only (0 = pass, 1 = fail).
"""

from functools import lru_cache
import hashlib
import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODELS = ROOT / "kernel" / "models"
README = MODELS / "README.md"
# Function identifiers in mapping cells are not restricted to a prefix.
NAME_RE = re.compile(r"`([a-z][a-z0-9_]*)`")
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


@lru_cache(maxsize=8)
def masked_sources(sources: str) -> str:
    """Preserve offsets while masking braces in comments and string literals."""
    return re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"',
                  lambda match: re.sub(r'[^\n]', ' ', match[0]), sources)


def function_body(name: str, sources: str) -> str | None:
    code = masked_sources(sources)
    match = re.search(rf"^(?:private )?(?:inline |noinline )?fn {name}\(",
                      code, re.M)
    if match is None:
        return None
    depth, position = 1, match.end()
    while depth:
        depth += (code[position] == '(') - (code[position] == ')')
        position += 1
    brace = code.index('{', position)
    if code[brace - 1] == '!':
        brace = code.index('{', code.index('}', brace) + 1)
    depth, end = 1, brace + 1
    while depth:
        depth += (code[end] == '{') - (code[end] == '}')
        end += 1
    return sources[match.start():end]


def normalised(body: str) -> str:
    """The body with comments and whitespace outside string literals gone."""
    out = []
    i = 0
    while i < len(body):
        if body.startswith("//", i):
            i = body.find("\n", i) % (len(body) + 1)
        elif body.startswith("/*", i):
            i = body.find("*/", i + 2) + 2 or len(body)
        elif body[i] == '"':
            end = i + 1
            while end < len(body) and body[end] != '"':
                end += 2 if body[end] == "\\" else 1
            out.append(body[i:end + 1])
            i = end + 1
        else:
            if not body[i].isspace():
                out.append(body[i])
            i += 1
    return "".join(out)


def stamped_names(cells: list[str]) -> list[str]:
    """The functions a row maps, then the guards its dropped paths rely on."""
    guards = re.findall(r"guarded: `([a-z][a-z0-9_]*)`", cells[3])
    return NAME_RE.findall(cells[1]) + guards


def row_hash(names: list[str], sources: str) -> str:
    digest = hashlib.sha256()
    for name in names:
        digest.update(normalised(function_body(name, sources) or "").encode())
        digest.update(b"\0")
    return digest.hexdigest()[:12]


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
    if len(cells) != 5:
        return [f"{cells[0]} has {len(cells)} cells, not 5"]
    errors = [f"{model}.tla does not define action {action}"
              for action in ACTION_RE.findall(cells[0])
              if action not in tla_defs.get(model, set())]
    errors += [f"{cells[0]} maps to {name}, which no kernel .tkb file "
               "defines; update the row and re-read the model's action "
               "against the code that replaced it"
               for name in missing(NAME_RE.findall(cells[1]), sources)]
    errors += dropped_errors(model, cells[3], tla_defs, sources)
    stamp = f"`{row_hash(stamped_names(cells), sources)}`"
    if not errors and cells[4] != stamp:
        errors.append(f"{cells[0]}: a function it maps changed since the "
                      f"row was reviewed ({cells[4]}, now {stamp}). Re-read "
                      "the row and the model's action against the code, "
                      "then run this script with --restamp")
    return errors


def restamp(text: str, sources: str) -> str:
    lines = []
    for line in text.splitlines(keepends=True):
        if line.startswith("| `"):
            cells = line.rstrip("\n").strip("|").split("|")
            if len(cells) == 5:
                cells[4] = " `" + row_hash(stamped_names(cells), sources) + "` "
                line = "|" + "|".join(cells) + "|\n"
        lines.append(line)
    return "".join(lines)


def controls_fail(tla_defs: dict[str, set[str]], sources: str) -> list[str]:
    """Rows that must be refused; a name for each one that is not."""
    refused = {
        "absent function": ["`Dispatch`", "`kernel_model_map_control_absent`",
                            "x", "nothing", ""],
        "bare drop": ["`Dispatch`", "`kernel_process_secondary_start`", "x",
                      "affinity is dropped", ""],
        "absent action": ["`Dispatch`", "`kernel_process_secondary_start`",
                          "x", "a -- modelled elsewhere: `Wait4Block.Absent`", ""],
        "absent activity": ["`Dispatch`", "`kernel_process_secondary_start`",
                            "x", "a -- guarded: `scheduled_process_start` "
                            "fail-stops with `control-absent`", ""],
        "guard elsewhere": ["`Dispatch`", "`kernel_process_secondary_start`",
                            "x", "a -- guarded: `scheduled_process_start` "
                            "fail-stops with `reap-on-owned-stack`", ""],
        "absent property": ["`Dispatch`", "`kernel_process_secondary_start`",
                            "x", "a -- irrelevant to `ControlAbsent`: no", ""],
    }
    failed = [name for name, cells in refused.items()
              if not row_errors("StackOwnership", cells, tla_defs, sources)]
    body = "fn f() -> usize {\n    // why\n    let s = \"a  // b\";\n    return 1;\n}\n"
    commented = body.replace("// why", "/* reworded */ // other")
    changed = body.replace("return 1", "return 2")
    string = body.replace("a  // b", "a // b")
    if row_hash(["f"], body) != row_hash(["f"], commented):
        failed.append("comment-only edit restamps")
    if row_hash(["f"], body) == row_hash(["f"], changed):
        failed.append("body edit keeps its stamp")
    if row_hash(["f"], body) == row_hash(["f"], string):
        failed.append("string edit keeps its stamp")
    for qualifier in ("inline ", "noinline ", "private inline "):
        qualified = body.replace("fn f()", qualifier + "fn f()")
        if function_body("f", qualified) is None:
            failed.append(qualifier + "function omitted")
        if row_hash(["f"], qualified) == row_hash(
                ["f"], qualified.replace("return 1", "return 2")):
            failed.append(qualifier + "body edit keeps its stamp")
    nested = 'fn f() {\nif (true) {\n}\nlet text = "}"; // }\nreturn 1;\n}\n'
    if row_hash(["f"], nested) == row_hash(["f"], nested.replace("return 1", "return 2")):
        failed.append("outdented nested block truncates the mapped function")
    # Exercise names through table parsing, not row_hash's explicit name list:
    # the original prefix allowlist silently omitted every uart_ function.
    uart_body = body.replace("fn f()", "fn uart_model_map_control()")
    uart_cells = ["`Writer`", "`uart_model_map_control`", "one byte",
                  "capacity -- irrelevant to `Writer`: bounded", ""]
    uart_cells[4] = "`" + row_hash(stamped_names(uart_cells), uart_body) + "`"
    uart_defs = {"Control": {"Writer"}}
    if row_errors("Control", uart_cells, uart_defs, uart_body):
        failed.append("UART positive row refused")
    changed_errors = row_errors("Control", uart_cells, uart_defs,
                               uart_body.replace("return 1", "return 2"))
    if not any("a function it maps changed" in error for error in changed_errors):
        failed.append("UART body edit keeps its table stamp")
    absent_cells = uart_cells.copy()
    absent_cells[1] = "`uart_model_map_control_absent`"
    absent_errors = row_errors("Control", absent_cells, uart_defs, uart_body)
    if not any("which no kernel .tkb file defines" in error for error in absent_errors):
        failed.append("absent UART function accepted")
    # An unrelated prefix must not recreate the same omission later.
    other_cells = uart_cells.copy()
    other_cells[1] = "`console_model_map_control`"
    other_body = uart_body.replace("uart_model_map_control", "console_model_map_control")
    other_cells[4] = "`" + row_hash(stamped_names(other_cells), other_body) + "`"
    other_errors = row_errors("Control", other_cells, uart_defs,
                              other_body.replace("return 1", "return 2"))
    if not any("a function it maps changed" in error for error in other_errors):
        failed.append("another prefix keeps its table stamp")
    return failed


def main() -> int:
    tla_defs = {path.stem: defined_names(path.read_text(encoding="utf-8"))
                for path in MODELS.glob("*.tla")}
    sources = "\n".join(path.read_text(encoding="utf-8")
                        for path in sorted((ROOT / "kernel").rglob("*.tkb")))
    if sys.argv[1:] == ["--restamp"]:
        README.write_text(restamp(README.read_text(encoding="utf-8"), sources),
                          encoding="utf-8")
    rows = table_rows(README.read_text(encoding="utf-8"))
    failed = False
    for model, cells in rows:
        for error in row_errors(model, cells, tla_defs, sources):
            print(f"ERROR model-function-map: kernel/models/README.md "
                  f"{model}: {error}")
            failed = True
    if failed:
        print("FAIL model-function-map: an action row points at nothing, "
              "drops a path without saying why that is safe, or maps code "
              "changed since its review")
        return 1
    if not_refused := controls_fail(tla_defs, sources):
        print("FAIL model-function-map: negative control(s) "
              f"{', '.join(not_refused)} were not refused, so this check "
              "proves nothing")
        return 1
    drops = sum(len(cells[3].split("; ")) for _, cells in rows
                if len(cells) == 5 and cells[3] != "nothing")
    report_pass(
        "model-function-map",
        f"{len(rows)} action row(s) name existing actions and functions, "
        f"{drops} dropped path(s) are each justified, every row's review "
        "stamp matches its functions, and an unjustified row, a body edit "
        "and a string edit are refused while a comment edit is not",
        action_rows=len(rows),
        dropped_paths=drops,
        models=len({model for model, _ in rows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
