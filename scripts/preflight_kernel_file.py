#!/usr/bin/env python3
"""List every registry a new, moved or renamed kernel file must join.

GitHub issue #721. Adding a kernel source file, assembly file or lane runner
touches registries that only a full build or the fast gate names, one at a
time: the execution-model coverage, the Makefile's unused-function lists, the
raw-dereference budget, the wall-clock bounds, the model function map, the
assembly entries, a lane's artifact root and its port block. This reports all
of them at once, in seconds, without building.

It is a convenience, not a gate; the checks stay authoritative. Where it can,
it runs the check itself and keeps the lines that name the file, so it reads
the tree with the check's own parser rather than a copy of it. Where only a
build can answer (the compiler's raw-dereference audit, which target compiles
the file), it says "after build" rather than guessing.

Usage: preflight_kernel_file.py [--root DIR] PATH|OLD=NEW ...
  PATH     a new or changed .tkb, .S or scripts/run_kernel_*.sh
  OLD=NEW  a move or rename; tracked references to OLD are reported as stale
Exit status is 0 when nothing is missing or stale, 1 otherwise.
"""

import argparse
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

from buildcheck_kernel_unused_coverage import makefile_list  # noqa: E402
from measure_trusted_base import read_raw_deref_budget  # noqa: E402

# Tree checks that name a kernel source file, a function in one, or a runner
# when it is missing from their registry. Each is a langcheck member, so each
# runs in well under a second.
TKB_CHECKS = ("check_execution_model_coverage.py",
              "check_kernel_lib_limitations_header.py",
              "check_platform_file_parity.py",
              "check_wall_clock_bounds.py")
ASM_CHECKS = ("check_kernel_asm_entries.py",)
RUNNER_CHECKS = ("check_lane_artifact_root.py", "check_qemu_lane_ports.py")
CHECKS_BY_KIND = dict(tkb=TKB_CHECKS, asm=ASM_CHECKS, runner=RUNNER_CHECKS)

UNUSED_LISTS = ("KERNEL_UNUSED_CHECKED", "KERNEL_UNUSED_CHECKED_QEMU",
                "KERNEL_UNUSED_CHECKED_RPI5", "KERNEL_UNUSED_EXEMPT",
                "KERNEL_UNUSED_NO_FUNCTIONS")

# Tracked files whose mention of an old path is history, not a registry row.
HISTORICAL = re.compile(r"^(HISTORY\.md|docs/KERNEL_GLOBAL\w*_\d{4}-\d{2}-\d{2}\.tsv"
                        r"|examples/)")

FN_RE = re.compile(r"^\s*(?:private\s+)?(?:inline\s+|noinline\s+)?fn\s+(\w+)", re.M)


def run_check(root: Path, name: str) -> tuple[int, list[str]]:
    result = subprocess.run([sys.executable, str(root / "scripts" / name)],
                            cwd=root, capture_output=True, text=True)
    return result.returncode, (result.stdout + result.stderr).splitlines()


def kind_of(path: str) -> str | None:
    if path.endswith(".tkb"):
        return "tkb"
    if path.endswith(".S"):
        return "asm"
    if re.fullmatch(r"scripts/run_kernel_[\w.-]*\.sh", path):
        return "runner"
    return None


def functions_in(text: str) -> set[str]:
    return set(FN_RE.findall(text))


def git_text(root: Path, revision_path: str) -> str:
    result = subprocess.run(["git", "show", revision_path], cwd=root,
                            capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else ""


def stale_references(root: Path, old: str) -> list[str]:
    result = subprocess.run(["git", "grep", "-n", "-F", old], cwd=root,
                            capture_output=True, text=True)
    rows = []
    for line in result.stdout.splitlines():
        where = line.split(":", 1)[0]
        if not HISTORICAL.match(where):
            rows.append(line)
    return rows


def relevant(lines: list[str], needles: set[str]) -> list[str]:
    keep = []
    for line in lines:
        if line.startswith("PASS "):
            continue
        if any(re.search(rf"(?<![\w/]){re.escape(n)}(?![\w])", line) for n in needles):
            keep.append(line)
    return keep


def report_path(root: Path, path: str, old: str | None,
                results: dict[str, tuple[int, list[str]]]) -> list[str]:
    """Lines for one file; each starts with ok, MISSING, STALE or AFTER BUILD."""
    kind = kind_of(path)
    out = []
    file = root / path
    if kind is None:
        return [f"MISSING  {path}: not a .tkb, .S or scripts/run_kernel_*.sh"]
    if not file.is_file():
        return [f"MISSING  {path}: no such file"]
    text = file.read_text(encoding="utf-8", errors="replace")
    functions = functions_in(text) if kind == "tkb" else set()
    old_functions = set()
    if old is not None and old.endswith(".tkb"):
        old_functions = functions_in(git_text(root, f"HEAD:{old}"))
    # A check prints a path relative to kernel/ or to the repository, or a
    # bare file name; any of them, or a function the file now defines, is
    # a line about this file.
    needles = {path, Path(path).name}
    if path.startswith("kernel/"):
        needles.add(path[len("kernel/"):])
    if old is not None:
        needles |= {old, Path(old).name}
        if old.startswith("kernel/"):
            needles.add(old[len("kernel/"):])
    needles |= functions | old_functions
    if kind == "asm":
        # The entry check names the Takibi function an assembly file calls.
        needles |= set(re.findall(r"\b(?:bl|b)\s+(\w+)", text))

    checks = CHECKS_BY_KIND[kind]
    for name in checks:
        status, lines = results[name]
        about = relevant(lines, needles)
        if status == 0:
            out.append(f"ok       {name}")
        elif about:
            out.extend(f"MISSING  {name}: {line.strip()}" for line in about)
        else:
            out.append(f"ok       {name} (it fails, but on lines naming "
                       "nothing in this file)")

    makefile = (root / "Makefile").read_text(encoding="utf-8")
    if kind == "tkb" and not path.endswith("_extern.tkb"):
        lists = [name for name in UNUSED_LISTS
                 if path in makefile_list(makefile, name)]
        if lists:
            out.append(f"ok       Makefile {', '.join(lists)}")
        else:
            out.append("MISSING  Makefile: in no KERNEL_UNUSED_* list; "
                       "buildcheck_kernel_unused_coverage.py refuses it after "
                       "build (CHECKED for both targets, _QEMU or _RPI5 for "
                       "the one that uses it, or EXEMPT with a reason)")
    if kind == "tkb":
        budget = read_raw_deref_budget(SCRIPTS / "raw_deref_budget.tsv"
                                       if root == SCRIPTS.parent
                                       else root / "scripts" / "raw_deref_budget.tsv")
        if path in budget:
            plain, io, _ = budget[path]
            out.append(f"AFTER BUILD raw_deref_budget.tsv: row plain={plain} "
                       f"io={io}; the compiler's audit decides whether it "
                       "still matches")
        elif re.search(r"\bas\s+\*", text):
            out.append("AFTER BUILD raw_deref_budget.tsv: no row, and the "
                       "file casts to a pointer; add a row with a reason if "
                       "the audit counts a dereference")
        else:
            out.append("ok       raw_deref_budget.tsv: no row and no pointer "
                       "cast (the audit after build is authoritative)")
        readme = (root / "kernel" / "models" / "README.md").read_text(
            encoding="utf-8")
        mapped = sorted(n for n in functions | old_functions
                        if f"`{n}`" in readme)
        if mapped:
            out.append("AFTER BUILD kernel/models/README.md maps "
                       f"{', '.join(mapped)}; a moved or renamed one needs "
                       "its row re-stamped (check_model_function_map.py)")
    if kind == "runner":
        if Path(path).name in makefile:
            out.append("ok       Makefile runs it")
        else:
            out.append("MISSING  Makefile: no recipe runs it, so no lane "
                       "and no port block covers it")
    if old is not None and (root / old).exists():
        out.append(f"ok       {old} still exists, so references to it are "
                   "not stale (a split, not a rename)")
    elif old is not None:
        for row in stale_references(root, old):
            out.append(f"STALE    {row}")
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.strip().splitlines()[0])
    parser.add_argument("--root", type=Path, default=SCRIPTS.parent)
    parser.add_argument("paths", nargs="+", metavar="PATH|OLD=NEW")
    args = parser.parse_args(argv)
    root = args.root.resolve()

    targets = []
    for arg in args.paths:
        old, _, new = arg.rpartition("=")
        targets.append((new, old or None))
    needed = set()
    for new, _ in targets:
        kind = kind_of(new)
        needed |= set(CHECKS_BY_KIND.get(kind, ()))
    with ThreadPoolExecutor() as pool:
        futures = {name: pool.submit(run_check, root, name) for name in needed}
        results = {name: future.result() for name, future in futures.items()}

    problems = 0
    for new, old in targets:
        title = f"{old} -> {new}" if old else new
        print(f"preflight {title}")
        for line in report_path(root, new, old, results):
            print(f"  {line}")
            if line.startswith(("MISSING", "STALE")):
                problems += 1
    print(f"preflight: {problems} missing or stale row(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
