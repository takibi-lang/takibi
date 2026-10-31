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
- the frame API ratchet (check_frame_api.py RATCHET, #1018), when present;
- the unprotected globals (scripts/global_protection_allowlist.tsv rows,
  which buildcheck_global_protection.py holds to the compiler's
  --facts globals.tsv tables, #1012);
- the premises no ratchet of its own counts (#1157): build checks named in
  TRUSTED_BASE.md (scripts/trust_checks.tsv, each with its successor), TLA+
  review stamps in kernel/models/README.md, production static_asserts naming
  KERNEL_PREEMPTIBLE or the core count;
- generated raw dereference sites apart from kernel files;
- each second judge's disagreements that became defects
  (scripts/trust_judge_defects.tsv).

Build-measured categories (`--facts rawsites.tsv` per target and per mint
file, the same total without the probe-linked `*_evidence.tkb` files, each
judge's obligations) are recorded only by `--append --build-dir kernel/build`
and are not re-measured by the fast check. A build row is compared with the
last entry that has it, so an append without a build skips no attribution.

Modes:
  check_trust_ledger.py                 check the series and the tree
  check_trust_ledger.py --report [--build-dir DIR]
                                        every category, its count and its date
                                        (make trustedbasecheck)
  check_trust_ledger.py --append [--reason CAT=TEXT ...] [--build-dir DIR]
                                        append today's entry

The check refuses: an entry whose changed category has no reason; a fallen
trust count whose reason names no rule in RULES; a risen trust count whose
reason cites no issue; dates going backwards; and the tree above the last
entry in a trust category (or below it in a judge category), which is growth
the series has not attributed yet; and a script TRUSTED_BASE.md names with no
row in scripts/trust_checks.tsv, or a row with no such mention or no successor. A fall in the tree is not refused: it is
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
    "unprotected_globals": (TRUST, "production let mut globals whose type shows no protection (scripts/global_protection_allowlist.tsv rows, #1012)"),
    "trust_build_checks": (TRUST, "scripts TRUSTED_BASE.md names as carrying trust (scripts/trust_checks.tsv)"),
    "tla_review_stamps": (TRUST, "review stamps in kernel/models/README.md"),
    "static_assert_premises": (TRUST, "production static_asserts naming KERNEL_PREEMPTIBLE or the core count"),
    "raw_deref_generated": (TRUST, "raw dereference budget of generated <protocol ...> files"),
    "judge_defects_range": (JUDGE, "z3 over ranges: disagreements that became defects (#952)"),
    "judge_defects_init": (JUDGE, "z3 over init intervals: disagreements that became defects (#954)"),
    "judge_defects_region_overlay": (JUDGE, "z3 over regions and overlays: disagreements that became defects (#986 slice 2)"),
    "per_cpu_stores": (JUDGE, "per_cpu store globals (#704, #638)"),
    # Build-measured: recorded by --append --build-dir only.
    "raw_sites_qemu": (TRUST, "--facts rawsites.tsv total, QEMU main.o"),
    "raw_sites_rpi5": (TRUST, "--facts rawsites.tsv total, RPi5 main.o"),
    "raw_sites_production_qemu": (TRUST, "the same, without *_evidence.tkb: the production image apart from the probe-linked one (from the facts, #986 slice 6 owns a real image)"),
    "raw_sites_production_rpi5": (TRUST, "the same, RPi5"),
    "range_obligations_qemu": (JUDGE, "z3 range obligations emitted, QEMU main.o (#952)"),
    "judge_obligations_range": (JUDGE, "z3 over ranges: obligations checked, QEMU main.o (#952)"),
    "judge_obligations_init": (JUDGE, "z3 over init intervals: obligations checked, QEMU main.o (#954)"),
    "judge_obligations_region_overlay": (JUDGE, "z3 over regions and overlays: obligations checked, QEMU main.o (#986 slice 2)"),
}
BUILD_ONLY = {name for name in CATEGORIES
              if name.startswith(("raw_sites_", "range_obligations_", "judge_obligations_"))}
# One build row per mint file, named raw_sites_file:<path>.
PER_FILE = "raw_sites_file:"
# Before #1157 a build row was compared only with the entry just before it, so
# the 46 older entries let falls and rises cross a build-less gap unattributed
# (raw_sites_qemu 331 -> 312 at entry 15). The series is not rewritten; the
# comparison holds from the first entry #1157 appended.
BUILD_ROWS_COMPARED_FROM = 46
# Rows that add up to the ledger's total: discrete premises, not lines of code
# (the frame's and the assembly's lines) and not what the judges check.
NOT_IN_TOTAL = {"frame_lines", "assembly_lines", "raw_sites_qemu", "raw_sites_rpi5",
                "raw_sites_production_qemu", "raw_sites_production_rpi5"}

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
    "assembly is a leaf": "#1133",
    "typed protection": "#1012",
    "BootOnce": "#1013",
    "code removed": "dead code deleted with no replacement",
    "category split": "the sites moved to another category; none left the base",
}

ISSUE = re.compile(r"#\d+")
PREMISE = re.compile(r"\bstatic_assert\s*\(\s*KERNEL_(?:PREEMPTIBLE|ACTIVE_CORES)\b")
STAMP = re.compile(r"`[0-9a-f]{12}`")
NAMED_SCRIPT = re.compile(r"\b((?:check|buildcheck|measure|run|lz4)_[a-z0-9_]+\.(?:py|sh))\b")
TRUST_CHECKS = ROOT / "scripts" / "trust_checks.tsv"
JUDGE_DEFECTS = ROOT / "scripts" / "trust_judge_defects.tsv"


def tsv_rows(path):
    return [line.split("\t") for line in path.read_text().splitlines()
            if line.strip() and not line.startswith("#")]


def named_check_problems(document, rows):
    """A script TRUSTED_BASE.md names needs a row with a successor, and only
    such a script has one (#986 slice 3's rule, on the ledger's list)."""
    named = {m for m in NAMED_SCRIPT.findall(document)
             if (ROOT / "scripts" / m).exists()}
    listed = {row[0] for row in rows}
    problems = [f"TRUSTED_BASE.md names scripts/{name} with no row in "
                "scripts/trust_checks.tsv" for name in sorted(named - listed)]
    problems += [f"scripts/trust_checks.tsv lists {name}, which TRUSTED_BASE.md "
                 "does not name" for name in sorted(listed - named)]
    problems += [f"scripts/trust_checks.tsv: {row[0]} has no successor (or "
                 "'permanent')" for row in rows
                 if len(row) != 3 or not row[2].strip()]
    return problems


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


def handwritten_assembly_lines(texts):
    """Lines of kernel assembly a person wrote. A build writes generated
    assembly into the source tree (exception_context_offsets.inc); it is the
    compiler's, and counting it made every built tree fail this check."""
    return sum(len(text.splitlines()) for relative, text in texts.items()
               if "build" not in Path(relative).parts
               and "GENERATED" not in text[:512])


def measure_tree():
    counts = {}
    mints = mint_list(KERNEL / "RAW_MINT_FILES")
    counts["raw_mint_files"] = len(mints)
    counts["frame_lines"] = sum(
        len((ROOT / m).read_text().splitlines()) for m in mints)
    counts["device_semantics_files"] = len(
        mint_list(KERNEL / "DEVICE_SEMANTICS_FILES"))

    plain = io = builtin = generated = 0
    for line in (ROOT / "scripts" / "raw_deref_budget.tsv").read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if fields[0] == "<builtin region>":
            builtin += int(fields[1]) + int(fields[2])
        elif fields[0].startswith("<protocol "):
            generated += int(fields[1]) + int(fields[2])
        else:
            plain += int(fields[1])
            io += int(fields[2])
    counts["raw_deref_plain"] = plain
    counts["raw_deref_io"] = io
    counts["raw_deref_builtin_region"] = builtin
    counts["raw_deref_generated"] = generated

    sources = kernel_sources()
    unsafe = re.compile(r"\bunsafe\s*\{")
    extern = re.compile(r"^\s*(?:pub\s+)?extern\s+fn\b", re.M)
    stop = re.compile(r"\bkernel_invariant_stop(?:_with_frame)?\s*\(")
    counts["unsafe_blocks"] = counts["extern_fns"] = 0
    counts["invariant_stop_sites"] = 0
    counts["static_assert_premises"] = 0
    for path in sources:
        code = code_only(path.read_text())
        counts["extern_fns"] += len(extern.findall(code))
        if production(path):
            counts["unsafe_blocks"] += len(unsafe.findall(code))
            counts["static_assert_premises"] += len(PREMISE.findall(code))
            counts["invariant_stop_sites"] += sum(
                1 for m in stop.finditer(code)
                if not code[max(0, m.start() - 10):m.start()].rstrip().endswith("fn"))
    counts["assembly_lines"] = handwritten_assembly_lines({
        str(p.relative_to(KERNEL)): p.read_text()
        for p in sorted(list(KERNEL.rglob("*.S")) + list(KERNEL.rglob("*.inc")))})

    sys.path.insert(0, str(ROOT / "scripts"))
    import check_per_cpu_arrays as per_cpu
    import check_raw_cpu_id_sites as cpu_id
    texts = {str(p.relative_to(ROOT)): p.read_text() for p in sources}
    found, stores = per_cpu.scan(texts)
    counts["per_cpu_ordinary_arrays"] = len(per_cpu.LISTED)
    counts["per_cpu_stores"] = sum(1 for e in found.values() if e in stores)
    counts["raw_cpu_id_calls"] = sum(
        n for n, kind, _ in cpu_id.LISTED.values() if kind != cpu_id.MINT)

    counts["trust_build_checks"] = len(tsv_rows(TRUST_CHECKS))
    counts["tla_review_stamps"] = len(STAMP.findall(
        (KERNEL / "models" / "README.md").read_text()))
    judges = [row[0] for row in tsv_rows(JUDGE_DEFECTS)]
    for judge in ("range", "init", "region_overlay"):
        counts[f"judge_defects_{judge}"] = judges.count(judge)

    counts["unprotected_globals"] = len(mint_list(
        ROOT / "scripts" / "global_protection_allowlist.tsv"))

    frame_api = ROOT / "scripts" / "check_frame_api.py"
    if frame_api.exists():
        value = literal_assignment(frame_api, "RATCHET")
        if isinstance(value, (ast.Dict, ast.Set, ast.List, ast.Tuple)):
            counts["frame_api_ratchet"] = len(
                value.keys if isinstance(value, ast.Dict) else value.elts)
    return counts


def measure_build(build_dir):
    counts = {}
    mints = set(mint_list(KERNEL / "RAW_MINT_FILES"))
    for target in ("qemu", "rpi5"):
        tsv = build_dir / target / "main.o.facts" / "rawsites.tsv"
        if tsv.exists():
            counts.update(raw_site_counts(target, tsv.read_text(), mints))
    obligations = build_dir / "qemu" / "main.o.facts" / "rangeobl"
    if obligations.is_dir():
        files = list(obligations.glob("*.smt2"))
        counts["range_obligations_qemu"] = len(files)
        counts.update(judge_obligation_counts(f.read_text() for f in files))
    return counts


def raw_site_counts(target, text, mints):
    """rawsites.tsv is `count<TAB>file`, its path as the compiler was given it."""
    total = production = 0
    per_mint = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        count, path = line.split("\t")[:2]
        # The first: kernel/arch/arm64/kernel/ holds a second such component.
        marker = path.find("/kernel/")
        relative = path[marker + 1:] if marker >= 0 else path
        total += int(count)
        if not relative.endswith("_evidence.tkb"):
            production += int(count)
        if relative in mints and int(count):
            per_mint[f"{PER_FILE}{target}:{relative}"] = int(count)
    return {f"raw_sites_{target}": total,
            f"raw_sites_production_{target}": production, **per_mint}


def judge_obligation_counts(texts):
    """One count per judge, read from each obligation's own header and rule."""
    counts = {"judge_obligations_range": 0, "judge_obligations_init": 0,
              "judge_obligations_region_overlay": 0}
    for text in texts:
        rule = re.search(r"^; rule: (\S+)", text, re.M)
        name = rule.group(1) if rule else ""
        if name in ("region", "overlay") or name.startswith("size-"):
            counts["judge_obligations_region_overlay"] += 1
        elif text.startswith("; takibi-init-obligation"):
            counts["judge_obligations_init"] += 1
        else:
            counts["judge_obligations_range"] += 1
    return counts


def is_build_row(category):
    return category in BUILD_ONLY or category.startswith(PER_FILE)


def category_kind(category):
    if category.startswith(PER_FILE):
        return TRUST
    return CATEGORIES[category][0] if category in CATEGORIES else None


def last_recorded(series, index, category):
    for entry in reversed(series[:index]):
        if category in entry["counts"]:
            return entry["counts"][category]
    return None


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
            if category not in CATEGORIES and not category.startswith(PER_FILE):
                problems.append(f"{where}: unknown category '{category}'")
        if index == 0:
            continue
        before = series[index - 1]
        if entry["date"] < before["date"]:
            problems.append(f"{where}: date goes backwards from {before['date']}")
        for category in sorted(set(entry["counts"]) | set(before["counts"])):
            old = before["counts"].get(category)
            new = entry["counts"].get(category)
            if is_build_row(category):
                if new is None:
                    continue  # an append without a build
                old = last_recorded(series, index, category)
                if index < BUILD_ROWS_COMPARED_FROM:
                    continue
            if old == new or category_kind(category) is None:
                continue
            if old is None or new is None:
                if is_build_row(category):
                    continue  # first recorded here
                reason = entry["changes"].get(category, "")
                if not reason.strip():
                    problems.append(f"{where}: {category} appeared or vanished "
                                    "with no reason")
                continue
            reason = entry["changes"].get(category, "")
            kind = category_kind(category)
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
            # A category whose source appeared after the last entry (the
            # frame API ratchet before #1018 lands) is held by its own
            # ratchet until the next append records it.
            continue
        kind = CATEGORIES[category][0]
        if (kind == TRUST and now > recorded) or (kind == JUDGE and now < recorded):
            problems.append(f"{category} is {now} in the tree against {recorded} "
                            f"in the last entry ({last['date']}): append an entry "
                            f"with --reason {category}='#NNN ...'")
    return problems


def premise_total(counts):
    return sum(count for name, count in counts.items()
               if category_kind(name) == TRUST and name not in NOT_IN_TOTAL
               and not name.startswith(PER_FILE))


def report(args):
    """Every category with a count and the date it was last recorded."""
    build_dir = Path(args[1]) if args[:1] == ["--build-dir"] else None
    series = json.loads(LEDGER.read_text())["series"]
    now = measure_tree()
    if build_dir is not None:
        now.update(measure_build(build_dir))
    print(f"Trust ledger: {len(series)} entries, last {series[-1]['date']} "
          f"at {series[-1]['head']}")
    names = list(CATEGORIES) + sorted(n for n in now if n.startswith(PER_FILE))
    for name in names:
        date, recorded = "never", None
        for entry in reversed(series):
            if name in entry["counts"]:
                date, recorded = entry["date"], entry["counts"][name]
                break
        moved = "" if now.get(name) == recorded or name not in now or recorded is None else f" (recorded {recorded})"
        shown = now.get(name, recorded)
        print(f"  {name:36} {category_kind(name):5} {shown!s:>7}  {date}{moved}")
    print(f"  {'total premises (DECISIONS 2026-10-13)':42} {premise_total(now):>7}  now, "
          f"{premise_total(series[-1]['counts'])} at the last entry")
    for row in tsv_rows(TRUST_CHECKS):
        print(f"  build check {row[0]}: {row[2]}")


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
    if handwritten_assembly_lines({"a/x.S": "mov x0, x1\n",
                                   "a/y.inc": "/* GENERATED by takibi */\n.set A, 8\n",
                                   "build/z.S": "nop\n"}) != 1:
        sys.exit("ERROR trust-ledger: control: generated or build assembly was counted")
    sites = raw_site_counts("qemu", "3\t/w/kernel/arch/kernel/a.tkb\n2\tkernel/kernel/b_evidence.tkb\n",
                            {"kernel/arch/kernel/a.tkb"})
    if sites != {"raw_sites_qemu": 5, "raw_sites_production_qemu": 3,
                 f"{PER_FILE}qemu:kernel/arch/kernel/a.tkb": 3}:
        sys.exit(f"ERROR trust-ledger: control: rawsites misread: {sites}")
    judged = judge_obligation_counts(["; takibi-init-obligation v1\n; rule: init\n",
                                      "; takibi-range-obligation v2\n; rule: add\n",
                                      "; takibi-init-obligation v1\n; rule: size-value\n"])
    if list(judged.values()) != [1, 1, 1]:
        sys.exit(f"ERROR trust-ledger: control: obligations misjudged: {judged}")
    rows = [["check_x.py", "t", "#1"]]
    document = "`scripts/check_x.py` and `scripts/check_trust_ledger.py`"
    missing = named_check_problems(document, rows)
    if not any("check_trust_ledger.py with no row" in p for p in missing):
        sys.exit("ERROR trust-ledger: control: a named check with no row was accepted")
    if not named_check_problems("no script here", [["check_trust_ledger.py", "t", "p"]]):
        sys.exit("ERROR trust-ledger: control: a stale check row was accepted")
    if not named_check_problems("scripts/check_trust_ledger.py", [["check_trust_ledger.py", "t", ""]]):
        sys.exit("ERROR trust-ledger: control: a row with no successor was accepted")
    build = dict(base["counts"], raw_sites_qemu=9)
    gap = [dict(base, counts=build)] + [entry(dict(base["counts"]), {})] * BUILD_ROWS_COMPARED_FROM
    gap.append(entry(dict(build, raw_sites_qemu=8), {}, date="2026-10-27"))
    if not series_problems(gap):
        sys.exit("ERROR trust-ledger: control: a build row's fall across an "
                 "entry without a build went unattributed")
    return len(cases) + 10


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
    if argv[:1] == ["--report"]:
        report(argv[1:])
        return
    if argv:
        sys.exit(f"usage: {sys.argv[0]} [--report [--build-dir DIR]] [--append [--reason CAT=TEXT] "
                 "[--build-dir DIR] [--date YYYY-MM-DD]]")
    series = json.loads(LEDGER.read_text())["series"]
    problems = series_problems(series)
    tree = measure_tree()
    if not problems:
        problems = tree_problems(series[-1], tree)
    problems += named_check_problems(
        (ROOT / "TRUSTED_BASE.md").read_text(), tsv_rows(TRUST_CHECKS))
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
