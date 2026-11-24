"""Read caller rules and compare them against emitted call graph facts.

The normal kernel recipes enforce the policy inside Takibi. These helpers
remain for the independent CPU authority and global admission audits.
"""

import pathlib

import call_graph_table

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIST = ROOT / "scripts" / "allowed_callers.tsv"


class ListError(Exception):
    pass


def read_list(path: pathlib.Path = LIST) -> list[dict]:
    rules = []
    names = set()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5 or not all(f.strip() for f in fields):
            raise ListError(f"{path.name}:{number}: expected 5 non-empty "
                            "tab-separated fields")
        name, helper, callers, issue, reason = fields
        allowed = set()
        for caller in callers.split(","):
            file, sep, function = caller.partition(":")
            if not sep or not file or not function:
                raise ListError(f"{path.name}:{number}: caller {caller!r} "
                                "is not file:function")
            if not (ROOT / file).is_file():
                raise ListError(f"{path.name}:{number}: caller file {file} "
                                "does not exist")
            allowed.add((file, function))
        if name in names:
            raise ListError(f"{path.name}:{number}: duplicate check {name}")
        names.add(name)
        rules.append({"name": name, "helper": helper, "allowed": allowed,
                      "issue": issue, "reason": reason})
    if not rules:
        raise ListError(f"{path.name}: no rows")
    return rules


def built_allowed(rule: dict, table: list[dict]) -> set:
    """The allowed callers whose file this kernel compiles."""
    files = {row["file"] for row in table}
    return {pair for pair in rule["allowed"] if pair[0] in files}


def problems_in(rule: dict, table: list[dict]) -> list[str]:
    helper, allowed = rule["helper"], built_allowed(rule, table)
    problems = []
    seen = set()
    for row in table:
        uses = [call_graph_table.callee_name(e) for e in row["callees"]]
        uses += [call_graph_table.callee_name(e) for e in row["values"]]
        if helper in uses:
            seen.add((row["file"], row["name"]))
            if (row["file"], row["name"]) not in allowed:
                problems.append(f"{row['file']}: {row['name']} uses {helper}; "
                                f"{rule['reason']} ({rule['issue']})")
    for file, name in sorted(allowed - seen):
        problems.append(f"{file}: {name} no longer calls {helper}; this check "
                        "would reason about nothing")
    return problems


def controls_fail(rule: dict, table: list[dict]) -> list[str]:
    helper, allowed = rule["helper"], built_allowed(rule, table)
    failed = []
    for field, label in (("callees", "a planted call"),
                         ("values", "a planted function-pointer reference")):
        planted = [dict(row) for row in table]
        victim = next(row for row in planted
                      if row["file"].startswith("kernel/")
                      and (row["file"], row["name"]) not in allowed)
        victim[field] = victim[field] + [helper + "@-"]
        if not problems_in(rule, planted):
            failed.append(f"{label} from {victim['name']}")
    if not allowed:
        return failed
    gone = [dict(row) for row in table]
    for row in gone:
        if (row["file"], row["name"]) in allowed:
            row["callees"] = [e for e in row["callees"]
                              if call_graph_table.callee_name(e) != helper]
            row["values"] = [e for e in row["values"]
                             if call_graph_table.callee_name(e) != helper]
    if not problems_in(rule, gone):
        failed.append(f"an allowed caller no longer calling {helper}")
    return failed
