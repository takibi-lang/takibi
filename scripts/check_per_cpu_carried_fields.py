#!/usr/bin/env python3
"""List every per_cpu field a task could carry across a move (#1331).

The compiler keeps a CpuHere from leaving its preempt_off region, and it makes
each access name this CPU's element. It says nothing about the VALUE: a field
written in one region and read in another is read from whichever CPU the task
stands on by then, and #1012's ratchet counts a per_cpu global as protected.
syscall_ext2_reader had that shape (#1323). Whether it is a defect is a
judgment about what the value means, so this check holds the judgment rather
than making it: every field of every `struct per_cpu` has a row of
scripts/per_cpu_carried_fields.tsv with

    cpu           the value describes this CPU, so a moved task rightly gets
                  the new CPU's answer
    not-migrated  only a context that never moves reads it
    task          the value belongs to one task's operation; the reason says
                  what a move does to it, and why that is tolerated

and the functions that write and read it, plus how many lexical regions touch
it (a function's own body is one region where no block encloses the use). A
new reader, writer or region is refused until the row is reviewed again. A
reader that returns the field (`return store[cpu].field;`) hands it out of the
region, so its callers are a column too. There is no computed "crosses regions" answer: one lexical region runs many times, so
a read below a write can still see an earlier run's value (MoveCostOpen does).

A use that is not `store[authority].field...` (an address, a whole element) is
refused: it would carry the field out of what this list can see. Two exact
exception publication/render borrows are admitted only while the independent
whole-file snapshot policy closes their adapters: the copy destination is a
writer and the borrowed renderer input a reader. Other addresses still fail.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only, function_header

ROOT = Path(__file__).resolve().parent.parent
TABLE = ROOT / "scripts" / "per_cpu_carried_fields.tsv"
VERDICTS = ("cpu", "not-migrated", "task")
COLUMNS = ("store", "field", "verdict", "regions", "writers", "readers", "callers", "reason")

FUNCTION = function_header()
STRUCT = re.compile(r"\bstruct\s+per_cpu\s+(\w+)\s*\{([^}]*)\}")
FIELD = re.compile(r"(?:^|[;{\s])(?:private\s+)?(\w+)\s*:", re.M)
GLOBAL = re.compile(r"\blet\s+mut\s+(\w+)\s*:\s*\[\s*(\w+)\s*;\s*KERNEL_MAX_CORES\s*\]")
REGION = re.compile(r"\bpreempt_off\s*\(\s*\w+\s*\)\s*\{")


def blocks_of(code):
    """(start, end) of each preempt_off block, in source order."""
    found = []
    for match in REGION.finditer(code):
        depth = 1
        at = match.end()
        while at < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[at], 0)
            at += 1
        found.append((match.start(), at))
    return found


def scan_file(code, path=None):
    """One file's declared fields, its uses {key: (writers, readers, regions)},
    and its refused shapes."""
    # Only the two already-reviewed snapshot borrows are admitted. Their
    # complete adapters/whole-file alias boundary are validated by the same
    # bounded policy as publication admission, not by file or store alone.
    borrowed = {}
    from check_exception_cpu_snapshots import PATH, problems as snapshot_problems
    if path == PATH and not snapshot_problems(code):
        borrowed = {
            ('crash_snapshot_per_core', 'crash_snapshot_copy_published', 'observed'): 'write',
            ('crash_snapshot_per_core', 'crash_snapshot_render_core', 'observed'): 'read',
        }
    fields = set()
    for name, body in STRUCT.findall(code):
        fields.update((name, field) for field in FIELD.findall(body))
    types = {name for name, _ in fields}
    stores = {g: t for g, t in GLOBAL.findall(code) if t in types}
    uses = {}
    problems = []
    if not stores:
        return fields, uses, problems
    # Same length, so positions and line numbers still hold.
    body = GLOBAL.sub(lambda m: " " * len(m.group(0)), code)
    starts = [(m.start(), m.group(1)) for m in FUNCTION.finditer(body)]
    blocks = blocks_of(body)
    for store, element in stores.items():
        shape = re.compile(
            r"((?<!&)&\s*)?\b" + store + r"\b(?:\s*\[\s*\w+\s*\]\s*\.\s*(\w+)"
            r"((?:\s*\.\s*\w+|\s*\[[^\]]*\])*)(\s*(?:[-+*/%|&^]|<<|>>)?=(?!=))?)?")
        for match in shape.finditer(body):
            line = body.count("\n", 0, match.start()) + 1
            field = match.group(2)
            function = "<top level>"
            for start, name in starts:
                if start > match.start():
                    break
                function = name
            borrow_mode = borrowed.get((store, function, field)) if match.group(1) else None
            if field is None or (match.group(1) and borrow_mode is None):
                problems.append(f"line {line}: {store} is used other than as "
                                f"{store}[authority].field")
                continue
            if (element, field) not in fields:
                problems.append(f"line {line}: {store}.{field} is not a field of {element}")
                continue
            function = "<top level>"
            for start, name in starts:
                if start > match.start():
                    break
                function = name
            region = (function, None)
            for start, end in blocks:
                if start < match.start() < end:
                    region = (function, start)
            entry = uses.setdefault((element, field), (set(), set(), set(), set()))
            entry[2].add(region)
            if re.search(r"\breturn\s+$", body[max(0, match.start() - 16):match.start()]):
                entry[3].add(function)
            assign = match.group(4)
            if assign or borrow_mode == 'write':
                entry[0].add(function)
            if borrow_mode == 'read' or (borrow_mode is None and (not assign or assign.strip() != "=")):
                entry[1].add(function)
    return fields, uses, problems


def callers_of(texts, accessors):
    """The functions, in any file, that name one of `accessors`."""
    found = set()
    if not accessors:
        return found
    pattern = re.compile(r"\b(?:" + "|".join(sorted(accessors)) + r")\b")
    for text in texts.values():
        code = code_only(text)
        if not pattern.search(code):
            continue
        starts = [(m.start(), m.end(), m.group(1)) for m in FUNCTION.finditer(code)]
        for match in pattern.finditer(code):
            function = "<top level>"
            header = False
            for start, end, name in starts:
                if start > match.start():
                    break
                function = name
                header = match.start() < end
            if not header:
                found.add(function)
    return found


def names(column):
    return sorted(column.split(",")) if column != "-" else []


def problems_of(texts, rows):
    """`texts`: {path: source}. `rows`: the table as dictionaries."""
    problems = []
    declared = set()
    uses = {}
    for path, text in sorted(texts.items()):
        fields, file_uses, file_problems = scan_file(code_only(text), path)
        problems += [f"{path}: {p}" for p in file_problems]
        declared |= fields
        uses.update(file_uses)
    listed = {(row["store"], row["field"]): row for row in rows}
    if len(listed) != len(rows):
        problems.append("a store and field is listed twice")
    for key in sorted(declared):
        if key not in listed:
            problems.append(f"{key[0]}.{key[1]} has no row: say what a moved "
                            "task does to it")
    for key, row in sorted(listed.items()):
        label = f"{key[0]}.{key[1]}"
        if key not in declared:
            problems.append(f"{label} is listed but not declared; remove its row")
            continue
        if row["verdict"] not in VERDICTS or not row["reason"].strip():
            problems.append(f"{label}: verdict {row['verdict']!r} or an empty reason")
        writers, readers, regions, accessors = uses.get(key, (set(), set(), set(), set()))
        found = {"writers": sorted(writers), "readers": sorted(readers),
                 "callers": sorted(callers_of(texts, accessors)),
                 "regions": len(regions)}
        wanted = {"writers": names(row["writers"]), "readers": names(row["readers"]),
                  "callers": names(row["callers"]),
                  "regions": int(row["regions"])}
        for column, value in found.items():
            if value != wanted[column]:
                problems.append(f"{label}: {column} are now {value}, the row says "
                                f"{wanted[column]}; review the row again")
    return problems


def read_table(path):
    lines = [l for l in path.read_text().splitlines() if l and not l.startswith("#")]
    if tuple(lines[0].split("\t")) != COLUMNS:
        sys.exit(f"ERROR per-cpu-carried-fields: {path.name}'s header is not {COLUMNS}")
    rows = []
    for line in lines[1:]:
        cells = line.split("\t")
        if len(cells) != len(COLUMNS):
            sys.exit(f"ERROR per-cpu-carried-fields: bad row: {line}")
        rows.append(dict(zip(COLUMNS, cells)))
    return rows


def controls():
    """The check must refuse the shapes it exists to catch."""
    source = ("struct per_cpu S { private x: usize; }\n"
              "private let mut g: [S; KERNEL_MAX_CORES];\n"
              "fn put() { preempt_off (c) { g[c].x = 1; } }\n"
              "fn get() -> usize { preempt_off (c) { return g[c].x; } }\n")
    row = {"store": "S", "field": "x", "verdict": "cpu", "regions": "2",
           "writers": "put", "readers": "get", "callers": "-", "reason": "r"}
    if problems_of({"a": source}, [row]):
        sys.exit("ERROR per-cpu-carried-fields: control: a clean store was refused")
    if problems_of({"a": source + "// fn o() { preempt_off (c) { g[c].x = 2; } }\n"}, [row]):
        sys.exit("ERROR per-cpu-carried-fields: control: a comment was refused")
    split = source.replace("g[c].x = 1; } }",
                           "g[c].x = 1; } preempt_off (c) { g[c].x = 2; } }")
    cases = {
        "no row": ({"a": source}, []),
        "new reader": ({"a": source + "fn o() -> usize { preempt_off (c) { return g[c].x; } }\n"}, [row]),
        "new caller of a returning reader": ({"a": source + "fn o() -> usize { return get(); }\n"}, [row]),
        "new writer": ({"a": source + "fn o() { preempt_off (c) { g[c].x = 2; } }\n"}, [row]),
        "second region in a function": ({"a": split}, [row]),
        "address": ({"a": source + "fn o() { preempt_off (c) { let p = &g[c].x; } }\n"}, [row]),
        "whole element": ({"a": source + "fn o() { preempt_off (c) { let e = g[c]; } }\n"}, [row]),
        "stale row": ({}, [row]),
        "bad verdict": ({"a": source}, [dict(row, verdict="fine")]),
        "empty reason": ({"a": source}, [dict(row, reason=" ")]),
        "twice": ({"a": source}, [row, row]),
    }
    for label, (texts, rows) in cases.items():
        if not problems_of(texts, rows):
            sys.exit(f"ERROR per-cpu-carried-fields: control '{label}' was not refused")
    return len(cases) + 2


def snapshot_controls(texts):
    """The two field borrows require independent closed-adapter evidence."""
    from check_exception_cpu_snapshots import PATH, problems as snapshot_problems
    from control_patch import replace_in_function
    source = texts[PATH]
    if snapshot_problems(source):
        sys.exit('ERROR per-cpu-carried-fields: snapshot policy baseline is not positive')
    _, uses, errors = scan_file(code_only(source), PATH)
    writers, readers, regions, accessors = uses[('CrashSnapshotCell', 'observed')]
    if (errors or writers != {'crash_snapshot_copy_published'} or
            readers != {'crash_snapshot_render_core', 'crash_snapshot_render_every_core'} or
            len(regions) != 3 or accessors):
        sys.exit('ERROR per-cpu-carried-fields: checked copy must count as writer and both render paths as readers')
    extra = source + '\nfn escaped(cpu: CpuHere) { let alias = &crash_snapshot_per_core[cpu].capture; }\n'
    whole = source + '\nfn escaped(cpu: CpuHere) { let alias = &crash_snapshot_per_core[cpu]; }\n'
    overwrite = replace_in_function(source, 'fn crash_snapshot_publish(',
        'write.process_pid = crash_snapshot_per_core[cpu].capture.process_pid;',
        'write.process_pid = crash_snapshot_per_core[cpu].capture.process_pid; write.process_pid = 0;')
    wrong_borrow = replace_in_function(source, 'fn crash_snapshot_copy_published(',
        '&crash_snapshot_per_core[cpu].observed', '&crash_snapshot_per_core[cpu].capture')
    alias = replace_in_function(source, 'fn crash_snapshot_copy_published(',
        'return CrashSnapshotReadResult::Ready;',
        'let alias = &crash_snapshot_per_core[cpu].observed; return CrashSnapshotReadResult::Ready;')
    cases = [(PATH, changed) for changed in (extra, whole, overwrite, wrong_borrow, alias)]
    cases.append(('kernel/elsewhere.tkb', source))
    for path, changed in cases:
        _, _, errors = scan_file(code_only(changed), path)
        if not errors:
            sys.exit('ERROR per-cpu-carried-fields: an unconfined snapshot borrow was admitted')
    # Comments do not affect the independent body policy or the accounting.
    _, changed, errors = scan_file(code_only(source + '\n// prose only\n'), PATH)
    if errors or changed != uses:
        sys.exit('ERROR per-cpu-carried-fields: prose changed snapshot accounting')
    return len(cases) + 2


def main():
    count = controls()
    texts = {}
    for path in sorted((ROOT / "kernel").rglob("*.tkb")):
        if "build" not in path.parts:
            texts[str(path.relative_to(ROOT))] = path.read_text()
    count += snapshot_controls(texts)
    rows = read_table(TABLE)
    problems = problems_of(texts, rows)
    if problems:
        for problem in problems:
            print(f"ERROR per-cpu-carried-fields: {problem}")
        sys.exit(1)
    kept = sum(1 for row in rows if row["verdict"] == "task")
    report_pass("per-cpu-carried-fields",
                f"{len(rows)} per_cpu fields reviewed for a move between regions, "
                f"{kept} task-carried; {count} controls", files=len(texts))


if __name__ == "__main__":
    main()
