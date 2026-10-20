#!/usr/bin/env python3
"""Checks whose controls run them in-process cache their per-file scans.

GitHub issue #808 (after #789). A control set calls its check once per planted
defect, each time over the whole kernel with one file changed. Uncached, that
re-scans every file per control; behind a small lru_cache bound (8 entries
over ~170 files) it is the same, since a loop over the tree evicts every entry
before it is reused. Both shapes pushed members toward the fast gate's 10 s
bound on a loaded allcheck, and a timeout there fails the land.

Two rules, both errors:

1. No `functools.lru_cache` / `functools.cache` in scripts/ outside
   scripts/source_scan.py. Its `per_file` is unbounded and refuses a mutable
   result, which a cache shared across controls must not hand out.
2. Every scripts/check_*.py that a scripts/check_*_controls.py imports
   in-process uses scripts/source_scan.py, directly or through a scripts
   module it imports, or is listed in REVIEWED with why its controls do not
   re-scan the tree.

Lexical (AST over scripts/*.py). It cannot tell whether a check that uses
per_file routes its *expensive* scan through it; that stays review.

Controls: scripts/check_source_scan_cache_controls.py.
"""

import ast
import pathlib
import sys

from pass_line import report_pass
from source_scan import per_file

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
HELPER = "source_scan"

# check module -> why its controls do not re-scan many files. Reviewed only.
REVIEWED = {
    "check_fd_clone_transaction": "scans one file (fd_table.tkb) per call",
    "check_agents_paths": "reads AGENTS.md and a file listing, not sources",
    "check_el0_raw_deref_audit": "reads the Makefile once",
    "check_ash_bin_inventory": "reads five fixed files, no tree walk",
    "check_wall_clock_bounds": "controls walk small synthetic trees; production runs once",
    "check_legacy_dma_rx_scope": "controls pass small synthetic source maps",
    "check_process_record_bare_uses": "scans one file (process.tkb) per call",
    "check_kernel_log_expectations": "controls call line_expectations on planted lines only",
    "check_liveness_proof_escapes": "function_qualifier controls import only its FN_RE",
    "check_kernel_interactive_httpd_protocol": "reads thirteen fixed files, no tree walk",
    "check_process_slot_zero": "controls walk two-file synthetic trees; the repository runs once",
}


def facts_of(tree: ast.Module) -> tuple:
    """(functools cache lines, imported module names), in one walk of the
    tree: the walk is this check's whole cost (#823 reopened)."""
    names = set()
    lines = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.module == "functools":
                if any(alias.name in ("lru_cache", "cache") for alias in node.names):
                    lines.append(node.lineno)
            if node.module and node.level == 0:
                # source_scan also holds code_only (GitHub issue #815), which
                # caches nothing: importing only that is not using the cache.
                if (node.module == HELPER
                        and not any(alias.name == "per_file" for alias in node.names)):
                    continue
                names.add(node.module.split(".")[0])
        elif (isinstance(node, ast.Attribute) and node.attr in ("lru_cache", "cache")
              and isinstance(node.value, ast.Name) and node.value.id == "functools"):
            lines.append(node.lineno)
    return lines, names


def problems(modules: dict, reviewed: dict = REVIEWED) -> list:
    """`modules` maps a scripts/ module name to its source text."""
    facts = {name: module_facts(name, text) for name, text in modules.items()}
    found = []
    for name, (lines, _) in sorted(facts.items()):
        if name == HELPER:
            continue
        for line in lines:
            found.append(f"scripts/{name}.py:{line}: functools cache; use "
                         f"source_scan.per_file (unbounded, refuses mutable results)")
    imports = {name: names & facts.keys() for name, (_, names) in facts.items()}

    def uses_helper(name: str, seen: frozenset = frozenset()) -> bool:
        if name in seen:
            return False
        direct = imports.get(name, set())
        return HELPER in direct or any(uses_helper(m, seen | {name}) for m in direct)

    checked = set()
    for name in sorted(facts):
        if not (name.startswith("check_") and name.endswith("_controls")):
            continue
        for target in sorted(imports[name]):
            if not target.startswith("check_") or target.endswith("_controls"):
                continue
            checked.add(target)
            if target in reviewed or uses_helper(target):
                continue
            found.append(f"scripts/{target}.py: imported in-process by scripts/{name}.py "
                         f"but scans without source_scan.per_file (cache its per-file "
                         f"scan, or list it in REVIEWED with why its controls do not "
                         f"re-scan the tree)")
    for target in sorted(reviewed):
        if target not in checked:
            found.append(f"REVIEWED lists {target}, which no controls import in-process: stale")
        elif uses_helper(target):
            found.append(f"REVIEWED lists {target}, which uses source_scan: stale")
    return found


@per_file
def module_facts(name: str, text: str):
    """(functools cache lines, imported module names) of one script, cached
    by content: the controls change one module per case."""
    tree = ast.parse(text, filename=f"scripts/{name}.py")
    lines, names = facts_of(tree)
    return tuple(lines), frozenset(names)


def tracked_modules() -> dict:
    return {path.stem: path.read_text(encoding="utf-8")
            for path in sorted(SCRIPTS.glob("*.py"))}


def main() -> int:
    modules = tracked_modules()
    found = problems(modules)
    if found:
        for line in found:
            print(f"FAIL source-scan-cache: {line}", file=sys.stderr)
        return 1
    report_pass("source-scan-cache",
                f"no functools cache outside source_scan in {len(modules)} scripts; "
                f"in-process checks cache per file or are reviewed ({len(REVIEWED)})",
                scripts=len(modules), reviewed=len(REVIEWED))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
