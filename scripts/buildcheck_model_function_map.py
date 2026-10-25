#!/usr/bin/env python3
"""The TLA+ action tables still point at real code and justify every drop.

Usage: buildcheck_model_function_map.py [--restamp] <qemu main.o>.callgraph.tsv
                                                    <rpi5 main.o>.callgraph.tsv

GitHub issues #601, #616 and #617. kernel/models/README.md maps each model action
to the Takibi functions it abstracts, and says what the action keeps and
what it drops. The model and the code are never compiled together, so this
check is what ties the table to both:

- every backquoted function name in a row's mapping cell has a definition in
  one of the compiled kernels, and every action a row names is defined in
  the section's .tla;
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

- every row's "reviewed" cell is a hash of the compiler's body_hash of every
  definition of the functions it maps and of the guards its dropped paths
  name. A change to any of them fails until a reviewer re-reads the row
  against the model and restamps it:

      make model-map-restamp

  (which builds both kernels' tables and runs this script with --restamp).
  The commit that restamps says what was reviewed. #609 changed
  kernel_process_child_exit in a way that mattered to StackOwnership.tla,
  and nothing asked for the model to be looked at.

GitHub issue #987 (maintainer's option A, 2026-10-25): the definitions,
their extents and their body hashes come from the compiler's
--emit-call-graph tables of the QEMU and RPi5 kernels (docs/CALL_GRAPH.md),
not from a brace-matching extractor over the source. body_hash is a digest
of the compiler's own tokens, so a comment or layout edit keeps a stamp and
any token change -- inside a string literal too -- moves it. A function
defined differently in the two kernels (a platform_* pair) contributes both
digests. The one text read left is the `guarded` form's activity: the
function's own lines, from the table's line/end_line, are searched for
`kernel_activity_set(KernelActivity::V)` with comments and blanks removed,
and the call must also be a resolved callee.

The hash says only "look again", not what is wrong, and it fires whether or
not any test exercises the change.

Exit code only (0 = pass, 1 = fail, 2 = usage).
"""

import hashlib
import pathlib
import re
import sys

import call_graph_table
from pass_line import report_pass
from source_scan import compact

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
    r'KernelActivity::(\w+)=>\{return"([a-z0-9-]+)"')
ACTIVITY_SET = "kernel_activity_set"
ACTIVITY_NAME = "kernel_activity_name"


class Program:
    """The definitions of the compiled kernels, by name.

    `rows` is every call-graph row of every table; a name defined in both
    kernels from one file is one definition (same file, line and hash).
    `read` returns a repository file's text; the controls replace it.
    """

    def __init__(self, rows: list[dict], read=None):
        self.defs: dict[str, list[dict]] = {}
        seen = set()
        for row in rows:
            if row["body_hash"] == "-":
                continue
            key = (row["name"], row["file"], row["line"], row["body_hash"])
            if key in seen:
                continue
            seen.add(key)
            self.defs.setdefault(row["name"], []).append(row)
        self.read = read or (lambda path: (ROOT / path).read_text(encoding="utf-8"))

    def defined(self, name: str) -> bool:
        return name in self.defs

    def digest(self, name: str) -> str:
        """The body hashes of every definition of `name`, sorted; '' if none."""
        return ",".join(sorted({row["body_hash"] for row in self.defs.get(name, [])}))

    def code(self, name: str) -> list[tuple[dict, str]]:
        """(row, its lines with comments and blanks removed) per definition."""
        out = []
        for row in self.defs.get(name, []):
            lines = self.read(row["file"]).splitlines()
            span = "\n".join(lines[int(row["line"]) - 1:int(row["end_line"])])
            out.append((row, compact(span)))
        return out


def read_tables(paths: list[str]) -> list[dict]:
    rows = []
    for path in paths:
        rows += call_graph_table.read(path)
    return rows


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


def stamped_names(cells: list[str]) -> list[str]:
    """The functions a row maps, then the guards its dropped paths rely on."""
    guards = re.findall(r"guarded: `([a-z][a-z0-9_]*)`", cells[3])
    return NAME_RE.findall(cells[1]) + guards


def row_hash(names: list[str], program: Program) -> str:
    digest = hashlib.sha256()
    for name in names:
        digest.update(program.digest(name).encode())
        digest.update(b"\0")
    return digest.hexdigest()[:12]


def activities(program: Program) -> dict[str, str]:
    """activity text -> KernelActivity variant, from kernel_activity_name."""
    return {text: variant for _, code in program.code(ACTIVITY_NAME)
            for variant, text in ACTIVITY_RE.findall(code)}


def sets_activity(program: Program, function: str, variant: str) -> bool:
    """Every definition of `function` calls kernel_activity_set with `variant`."""
    found = program.code(function)
    call = f"{ACTIVITY_SET}(KernelActivity::{variant})"
    return bool(found) and all(
        call in code and any(call_graph_table.callee_name(c) == ACTIVITY_SET
                             for c in row["callees"])
        for row, code in found)


def dropped_errors(model: str, cell: str, tla_defs: dict[str, set[str]],
                   program: Program) -> list[str]:
    """Why a dropped cell is not justified; empty when it is."""
    if cell == "nothing":
        return []
    errors = []
    names = None
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
            if names is None:
                names = activities(program)
            variant = names.get(activity)
            if not program.defined(function):
                errors.append(f"'{path}' is guarded by {function}, which "
                              "neither compiled kernel defines")
            elif variant is None:
                errors.append(f"'{path}' is guarded by activity {activity}, "
                              f"which {ACTIVITY_NAME} never returns")
            elif not sets_activity(program, function, variant):
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
               program: Program) -> list[str]:
    if len(cells) != 5:
        return [f"{cells[0]} has {len(cells)} cells, not 5"]
    errors = [f"{model}.tla does not define action {action}"
              for action in ACTION_RE.findall(cells[0])
              if action not in tla_defs.get(model, set())]
    errors += [f"{cells[0]} maps to {name}, which neither compiled kernel "
               "defines; update the row and re-read the model's action "
               "against the code that replaced it"
               for name in NAME_RE.findall(cells[1])
               if not program.defined(name)]
    errors += dropped_errors(model, cells[3], tla_defs, program)
    stamp = f"`{row_hash(stamped_names(cells), program)}`"
    if not errors and cells[4] != stamp:
        errors.append(f"{cells[0]}: a function it maps changed since the "
                      f"row was reviewed ({cells[4]}, now {stamp}). Re-read "
                      "the row and the model's action against the code, "
                      "then run `make model-map-restamp`")
    return errors


def restamp(text: str, program: Program) -> str:
    lines = []
    for line in text.splitlines(keepends=True):
        if line.startswith("| `"):
            cells = line.rstrip("\n").strip("|").split("|")
            if len(cells) == 5:
                cells[4] = " `" + row_hash(stamped_names(cells), program) + "` "
                line = "|" + "|".join(cells) + "|\n"
        lines.append(line)
    return "".join(lines)


def changed(rows: list[dict], name: str, column: str, value) -> list[dict]:
    """A copy of the table rows with every row of `name` given `value`."""
    if not any(row["name"] == name for row in rows):
        raise SystemExit(f"FAIL model-function-map: the negative control's "
                         f"subject {name} is not in the table")
    return [dict(row, **{column: value}) if row["name"] == name else row
            for row in rows]


def controls_fail(tla_defs: dict[str, set[str]], rows: list[dict],
                  readme_rows: list[tuple[str, list[str]]]) -> list[str]:
    """Defects that must be refused; a name for each one that is not."""
    program = Program(rows)
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
              if not row_errors("StackOwnership", cells, tla_defs, program)]
    # Every real row, with one mapped function's compiler digest moved, must
    # lose its stamp; and the first guarded row must lose its guard when the
    # guard's call to kernel_activity_set is gone from the table.
    for model, cells in readme_rows:
        names = stamped_names(cells) if len(cells) == 5 else []
        if not names or not program.defined(names[0]):
            continue
        moved = Program(changed(rows, names[0], "body_hash", "0" * 32))
        if not any("a function it maps changed" in error
                   for error in row_errors(model, cells, tla_defs, moved)):
            failed.append(f"{cells[0]} keeps its stamp when {names[0]} changes")
    guarded = next(((model, cells) for model, cells in readme_rows
                    if len(cells) == 5 and "guarded: `" in cells[3]), None)
    if guarded is None:
        failed.append("no guarded row to plant a lost guard in")
    else:
        model, cells = guarded
        guard = re.search(r"guarded: `(\w+)`", cells[3]).group(1)
        unset = Program(changed(rows, guard, "callees", []))
        if not row_errors(model, cells, tla_defs, unset):
            failed.append(f"{guard} still guards with no kernel_activity_set call")
    # Exercise names through table parsing, not row_hash's explicit name
    # list: the original prefix allowlist silently omitted every uart_
    # function. A synthetic one-row table stands for a defined function.
    def one(name, digest):
        return Program([{"name": name, "file": "kernel/x.tkb", "line": "1",
                         "end_line": "1", "body_hash": digest, "callees": []}])
    uart_cells = ["`Writer`", "`uart_model_map_control`", "one byte",
                  "capacity -- irrelevant to `Writer`: bounded", ""]
    uart = one("uart_model_map_control", "a" * 32)
    uart_cells[4] = "`" + row_hash(stamped_names(uart_cells), uart) + "`"
    uart_defs = {"Control": {"Writer"}}
    if row_errors("Control", uart_cells, uart_defs, uart):
        failed.append("UART positive row refused")
    if not any("a function it maps changed" in error for error in row_errors(
            "Control", uart_cells, uart_defs, one("uart_model_map_control", "b" * 32))):
        failed.append("UART body edit keeps its table stamp")
    absent_cells = uart_cells.copy()
    absent_cells[1] = "`uart_model_map_control_absent`"
    if not any("neither compiled kernel defines" in error for error in row_errors(
            "Control", absent_cells, uart_defs, uart)):
        failed.append("absent UART function accepted")
    # A second definition (the other kernel's platform_* twin) is reviewed too.
    twin = Program(uart.defs["uart_model_map_control"]
                   + [dict(uart.defs["uart_model_map_control"][0],
                           file="kernel/y.tkb", body_hash="c" * 32)])
    if not row_errors("Control", uart_cells, uart_defs, twin):
        failed.append("a second kernel's differing definition keeps the stamp")
    return failed


def main() -> int:
    args = sys.argv[1:]
    restamping = args[:1] == ["--restamp"]
    tables = args[1:] if restamping else args
    if not tables:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        rows = read_tables(tables)
    except (OSError, call_graph_table.TableError) as error:
        print(f"FAIL model-function-map: {error}")
        return 1
    program = Program(rows)
    tla_defs = {path.stem: defined_names(path.read_text(encoding="utf-8"))
                for path in MODELS.glob("*.tla")}
    if restamping:
        README.write_text(restamp(README.read_text(encoding="utf-8"), program),
                          encoding="utf-8")
    readme_rows = table_rows(README.read_text(encoding="utf-8"))
    failed = False
    for model, cells in readme_rows:
        for error in row_errors(model, cells, tla_defs, program):
            print(f"ERROR model-function-map: kernel/models/README.md "
                  f"{model}: {error}")
            failed = True
    if failed:
        print("FAIL model-function-map: an action row points at nothing, "
              "drops a path without saying why that is safe, or maps code "
              "changed since its review")
        return 1
    if not_refused := controls_fail(tla_defs, rows, readme_rows):
        print("FAIL model-function-map: negative control(s) "
              f"{', '.join(not_refused)} were not refused, so this check "
              "proves nothing")
        return 1
    drops = sum(len(cells[3].split("; ")) for _, cells in readme_rows
                if len(cells) == 5 and cells[3] != "nothing")
    report_pass(
        "model-function-map",
        f"{len(readme_rows)} action row(s) name existing actions and compiled "
        f"functions in {len(tables)} call-graph table(s), {drops} dropped "
        "path(s) are each justified, every row's review stamp matches the "
        "compiler's body hashes, and an unjustified row, a moved digest per "
        "row and a guard without its activity call are refused",
        action_rows=len(readme_rows),
        dropped_paths=drops,
        models=len({model for model, _ in readme_rows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
