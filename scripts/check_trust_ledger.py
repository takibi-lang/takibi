#!/usr/bin/env python3
"""The trust ledger: a dated series of the trusted base's counts (#986 slice 1).

`docs/TRUST_LEDGER.json` keeps one entry per checkpoint: the date, the HEAD
it measured, one count per category, and for every category whose count
changed since the previous entry the reason it changed. A count that fell
names the rule that retired it (one of RULES: header overlays, Place,
per_cpu, ...); a trust count that rose names the issue that accepted it.
That attribution is cheap at the moment a site leaves and expensive to
reconstruct later, which is why the series refuses an entry without it
(DECISIONS 2026-10-25, the Rust-comparison evidence).

Categories come from the ratchets that already exist, read from the tree so
the check needs no kernel build:

- the frame: kernel/RAW_MINT_FILES (file count and lines),
  kernel/DEVICE_SEMANTICS_FILES;
- raw dereference budget rows (scripts/raw_deref_budget.tsv, which
  `measure_trusted_base.py --check-raw-deref` holds to the compiler's audit);
- production `unsafe { }` blocks, handwritten assembly lines, `extern fn`;
- the per-CPU arrays still ordinary (check_per_cpu_arrays.py LISTED) and the
  per_cpu stores, raw `cpu_id()` calls (check_raw_cpu_id_sites.py);
- explicit `kernel_invariant_stop` call sites (#1031: containment, not trust
  removed, so a separate row);
- the frame API ratchet (check_frame_api.py RATCHET, #1018), when present.

Build-measured categories (`--emit-raw-site-counts` per target, z3 range
obligations) are recorded only by `--append --build-dir kernel/build` and are
not re-measured by the fast check.

Modes:
  check_trust_ledger.py                 check the series and the tree
  check_trust_ledger.py --append [--reason CAT=TEXT ...] [--build-dir DIR]
                                        append today's entry

The check refuses: an entry whose changed category has no reason; a fallen
trust count whose reason names no rule in RULES; a risen trust count whose
reason cites no issue; dates going backwards; and the tree above the last
entry in a trust category (or below it in a judge category), which is growth
the series has not attributed yet. A fall in the tree is not refused: it is
recorded, with its rule, at the next append.
"""

import ast
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"
LEDGER = ROOT / "docs" / "TRUST_LEDGER.json"

TRUST = "trust"   # should only fall; a rise needs an accepting issue
JUDGE = "judge"   # should only rise; a fall needs a reason

# category -> (kind, what it counts)
CATEGORIES = {
    "raw_mint_files": (TRUST, "files in kernel/RAW_MINT_FILES (the frame, #1017)"),
    "frame_lines": (TRUST, "lines of the RAW_MINT_FILES files"),
    "device_semantics_files": (TRUST, "files in kernel/DEVICE_SEMANTICS_FILES"),
    "raw_deref_plain": (TRUST, "plain raw dereference budget, kernel files"),
    "raw_deref_io": (TRUST, "io raw dereference budget, kernel files"),
    "raw_deref_builtin_region": (TRUST, "raw dereference budget of <builtin region>"),
    "unsafe_blocks": (TRUST, "unsafe { } blocks in kernel .tkb outside kernel/tests"),
    "assembly_lines": (TRUST, "lines of handwritten kernel .S/.inc"),
    "extern_fns": (TRUST, "extern fn declarations in kernel .tkb"),
    "per_cpu_ordinary_arrays": (TRUST, "[T; KERNEL_MAX_CORES] globals left ordinary (check_per_cpu_arrays LISTED)"),
    "raw_cpu_id_calls": (TRUST, "raw cpu_id() calls outside the CpuHere mint (check_raw_cpu_id_sites)"),
    "invariant_stop_sites": (TRUST, "kernel_invariant_stop call sites outside kernel/tests (#1031; containment)"),
    "frame_api_ratchet": (TRUST, "check_frame_api.py RATCHET entries (#1018)"),
    "per_cpu_stores": (JUDGE, "per_cpu store globals (#704, #638)"),
    # Build-measured: recorded by --append --build-dir only.
    "raw_sites_qemu": (TRUST, "--emit-raw-site-counts total, QEMU main.o"),
    "raw_sites_rpi5": (TRUST, "--emit-raw-site-counts total, RPi5 main.o"),
    "range_obligations_qemu": (JUDGE, "z3 range obligations emitted, QEMU main.o (#952)"),
}
BUILD_ONLY = {"raw_sites_qemu", "raw_sites_rpi5", "range_obligations_qemu"}

# The rules a fallen trust count may be attributed to (#986 comment of
# 2026-10-25). A new rule is added here with the issue that introduced it.
RULES = {
    "header overlays": "#637",
    "Place": "#637",
    "per_cpu": "#704",
    "built-in regions": "#672",
    "protocol declarations": "#720",
    "IoHandle": "#637",
    "checked indexing": "#637",
    "slot pool": "#981",
    "preempt_off": "#638",
    "AtomicWord": "#637",
    "value over stop": "#1031",
    "frame API": "#1018",
    "code removed": "dead code deleted with no replacement",
}

ISSUE = re.compile(r"#\d+")


def mint_list(path):
    return [line.strip() for line in path.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def kernel_sources():
    return [p for p in sorted(KERNEL.rglob("*.tkb"))
            if "build" not in p.relative_to(KERNEL).parts]


def production(path):
    return path.relative_to(KERNEL).parts[0] != "tests"


def literal_assignment(path, name):
    """The literal value assigned to top-level `name` in a Python file."""
    tree = ast.parse(path.read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return node.value
    return None


def measure_tree():
    counts = {}
    mints = mint_list(KERNEL / "RAW_MINT_FILES")
    counts["raw_mint_files"] = len(mints)
    counts["frame_lines"] = sum(
        len((ROOT / m).read_text().splitlines()) for m in mints)
    counts["device_semantics_files"] = len(
        mint_list(KERNEL / "DEVICE_SEMANTICS_FILES"))

    plain = io = builtin = 0
    for line in (ROOT / "scripts" / "raw_deref_budget.tsv").read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if fields[0] == "<builtin region>":
            builtin += int(fields[1]) + int(fields[2])
        else:
            plain += int(fields[1])
            io += int(fields[2])
    counts["raw_deref_plain"] = plain
    counts["raw_deref_io"] = io
    counts["raw_deref_builtin_region"] = builtin

    sources = kernel_sources()
    unsafe = re.compile(r"\bunsafe\s*\{")
    extern = re.compile(r"^\s*(?:pub\s+)?extern\s+fn\b", re.M)
    stop = re.compile(r"\bkernel_invariant_stop(?:_with_frame)?\s*\(")
    counts["unsafe_blocks"] = counts["extern_fns"] = 0
    counts["invariant_stop_sites"] = 0
    for path in sources:
        code = code_only(path.read_text())
        counts["extern_fns"] += len(extern.findall(code))
        if production(path):
            counts["unsafe_blocks"] += len(unsafe.findall(code))
            counts["invariant_stop_sites"] += sum(
                1 for m in stop.finditer(code)
                if not code[max(0, m.start() - 10):m.start()].rstrip().endswith("fn"))
    counts["assembly_lines"] = sum(
        len(p.read_text().splitlines())
        for p in sorted(list(KERNEL.rglob("*.S")) + list(KERNEL.rglob("*.inc")))
        if "build" not in p.relative_to(KERNEL).parts)

    sys.path.insert(0, str(ROOT / "scripts"))
    import check_per_cpu_arrays as per_cpu
    import check_raw_cpu_id_sites as cpu_id
    texts = {str(p.relative_to(ROOT)): p.read_text() for p in sources}
    found, stores = per_cpu.scan(texts)
    counts["per_cpu_ordinary_arrays"] = len(per_cpu.LISTED)
    counts["per_cpu_stores"] = sum(1 for e in found.values() if e in stores)
    counts["raw_cpu_id_calls"] = sum(
        n for n, kind, _ in cpu_id.LISTED.values() if kind != cpu_id.MINT)

    frame_api = ROOT / "scripts" / "check_frame_api.py"
    if frame_api.exists():
        value = literal_assignment(frame_api, "RATCHET")
        if isinstance(value, (ast.Dict, ast.Set, ast.List, ast.Tuple)):
            counts["frame_api_ratchet"] = len(
                value.keys if isinstance(value, ast.Dict) else value.elts)
    return counts


def measure_build(build_dir):
    counts = {}
    for target in ("qemu", "rpi5"):
        tsv = build_dir / target / "main.o.rawsites.tsv"
        if tsv.exists():
            counts[f"raw_sites_{target}"] = sum(
                int(line.split("\t")[0])
                for line in tsv.read_text().splitlines() if line.strip())
    obligations = build_dir / "qemu" / "main.o.rangeobl"
    if obligations.is_dir():
        counts["range_obligations_qemu"] = len(list(obligations.glob("*.smt2")))
    return counts


def series_problems(series):
    problems = []
    if not series:
        return ["the ledger has no entry"]
    for index, entry in enumerate(series):
        where = f"entry {index} ({entry.get('date')}, {entry.get('head')})"
        for key in ("date", "head", "counts", "changes"):
            if key not in entry:
                problems.append(f"{where}: missing '{key}'")
        if problems:
            continue
        for category in entry["counts"]:
            if category not in CATEGORIES:
                problems.append(f"{where}: unknown category '{category}'")
        if index == 0:
            continue
        before = series[index - 1]
        if entry["date"] < before["date"]:
            problems.append(f"{where}: date goes backwards from {before['date']}")
        for category in sorted(set(entry["counts"]) | set(before["counts"])):
            old = before["counts"].get(category)
            new = entry["counts"].get(category)
            if old == new or category not in CATEGORIES:
                continue
            if old is None or new is None:
                if category in BUILD_ONLY:
                    continue  # a build row present in one entry only
                reason = entry["changes"].get(category, "")
                if not reason.strip():
                    problems.append(f"{where}: {category} appeared or vanished "
                                    "with no reason")
                continue
            reason = entry["changes"].get(category, "")
            kind = CATEGORIES[category][0]
            shrank = new < old
            if not reason.strip():
                problems.append(f"{where}: {category} {old} -> {new} has no reason")
            elif kind == TRUST and shrank and not any(
                    reason.startswith(rule) for rule in RULES):
                problems.append(f"{where}: {category} {old} -> {new} fell but "
                                f"'{reason}' names no rule in RULES")
            elif (kind == TRUST) != shrank and not ISSUE.search(reason):
                problems.append(f"{where}: {category} {old} -> {new} grew the "
                                f"trusted base (or shrank a judge) but '{reason}' "
                                "cites no issue")
    return problems


def tree_problems(last, tree):
    problems = []
    for category, now in sorted(tree.items()):
        recorded = last["counts"].get(category)
        if recorded is None:
            problems.append(f"{category} = {now} is not in the last entry; "
                            "append an entry")
            continue
        kind = CATEGORIES[category][0]
        if (kind == TRUST and now > recorded) or (kind == JUDGE and now < recorded):
            problems.append(f"{category} is {now} in the tree against {recorded} "
                            f"in the last entry ({last['date']}): append an entry "
                            f"with --reason {category}='#NNN ...'")
    return problems


def controls():
    """The check must refuse the shapes it exists to catch."""
    base = {"date": "2026-10-25", "head": "a", "changes": {"*": "first entry"},
            "counts": {"raw_mint_files": 16, "per_cpu_stores": 3}}

    def entry(counts, changes, date="2026-10-26"):
        return {"date": date, "head": "b", "counts": counts, "changes": changes}

    good = [base, entry({"raw_mint_files": 15, "per_cpu_stores": 4},
                        {"raw_mint_files": "IoHandle: mmio left the list",
                         "per_cpu_stores": "per_cpu: #638"})]
    if series_problems(good):
        sys.exit(f"ERROR trust-ledger: control: a good series was refused: "
                 f"{series_problems(good)}")
    cases = {
        "unattributed fall": [base, entry({"raw_mint_files": 15, "per_cpu_stores": 3}, {})],
        "fall naming no rule": [base, entry({"raw_mint_files": 15, "per_cpu_stores": 3},
                                            {"raw_mint_files": "it got better"})],
        "growth citing no issue": [base, entry({"raw_mint_files": 17, "per_cpu_stores": 3},
                                               {"raw_mint_files": "needed it"})],
        "judge fall citing no issue": [base, entry({"raw_mint_files": 16, "per_cpu_stores": 2},
                                                   {"per_cpu_stores": "moved"})],
        "date backwards": [base, entry(dict(base["counts"]), {}, date="2026-10-01")],
        "unknown category": [base, entry(dict(base["counts"], bogus=1), {})],
        "empty series": [],
    }
    for label, series in cases.items():
        if not series_problems(series):
            sys.exit(f"ERROR trust-ledger: control '{label}' was not refused")
    if not tree_problems(base, {"raw_mint_files": 17, "per_cpu_stores": 3}):
        sys.exit("ERROR trust-ledger: control 'tree above the last entry' was not refused")
    if not tree_problems(base, {"raw_mint_files": 16, "per_cpu_stores": 2}):
        sys.exit("ERROR trust-ledger: control 'judge below the last entry' was not refused")
    if tree_problems(base, {"raw_mint_files": 15, "per_cpu_stores": 3}):
        sys.exit("ERROR trust-ledger: control: a fall in the tree was refused")
    return len(cases) + 3


def append(args):
    reasons, build_dir, date = {}, None, datetime.date.today().isoformat()
    it = iter(args)
    for arg in it:
        if arg == "--reason":
            category, _, text = next(it).partition("=")
            reasons[category] = text
        elif arg == "--build-dir":
            build_dir = Path(next(it))
        elif arg == "--date":
            date = next(it)
        else:
            sys.exit(f"usage: unknown argument {arg}")
    data = json.loads(LEDGER.read_text()) if LEDGER.exists() else {"series": []}
    counts = measure_tree()
    if build_dir is not None:
        counts.update(measure_build(build_dir))
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
                          capture_output=True, text=True, check=True).stdout.strip()
    changes = reasons if data["series"] else {"*": reasons.get("*", "first entry")}
    data["series"].append({"date": date, "head": head, "counts": counts,
                           "changes": changes})
    problems = series_problems(data["series"])
    if problems:
        for problem in problems:
            print(f"ERROR trust-ledger: {problem}")
        sys.exit("ERROR trust-ledger: nothing appended; give --reason for each")
    LEDGER.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")
    print(f"trust-ledger: appended {date} at {head} ({len(counts)} categories)")


def main(argv):
    count = controls()
    if argv[:1] == ["--append"]:
        append(argv[1:])
        return
    if argv:
        sys.exit(f"usage: {sys.argv[0]} [--append [--reason CAT=TEXT] "
                 "[--build-dir DIR] [--date YYYY-MM-DD]]")
    series = json.loads(LEDGER.read_text())["series"]
    problems = series_problems(series)
    tree = measure_tree()
    if not problems:
        problems = tree_problems(series[-1], tree)
    if problems:
        for problem in problems:
            print(f"ERROR trust-ledger: {problem}")
        sys.exit(1)
    report_pass("trust-ledger",
                f"{len(series)} dated entries, every change attributed; the "
                f"tree's {len(tree)} categories within the last entry; "
                f"{count} controls",
                entries=len(series), categories=len(tree), controls=count)


if __name__ == "__main__":
    main(sys.argv[1:])
