#!/usr/bin/env python3
"""Hold every `assume_init` site to TRUSTED_BASE.md's list (GitHub issue #764).

`unsafe { assume_init(x) }` tells the definite-initialization checker that
bytes were written by means it cannot see (#203). Each such site is a
trusted premise, so TRUSTED_BASE.md names each one, as `path:function`
(for example `kernel/kernel/syscall.tkb:syscall_path_view_here`), next to
the fact it relies on. This check refuses:

  * a function in maintained kernel/ or linux_user/ Takibi code that calls
    assume_init but is not listed;
  * a listed site whose function no longer calls assume_init (stale: an
    error, so the list never names code that is gone).

A site is the enclosing function: several calls in one function rest on one
premise. Comments are blanked first (source_scan.code_only, #815/#818), so a
comment naming assume_init is neither a site nor evidence for a listing.

Rung: a build check, not the compiler. The compiler does know every site,
but making it emit or verify the list would mean either running it over the
kernel from here (the fast gate forbids spawning) or teaching the compiler
to read a Markdown allowlist; the scan over comment-blanked source sees the
same calls, since assume_init is a builtin that cannot be aliased.
Controls: scripts/check_assume_init_sites_controls.py.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only, per_file

ROOT = Path(__file__).resolve().parent.parent
TRUSTED_BASE = ROOT / "TRUSTED_BASE.md"
TREES = ("kernel", "linux_user")
EXCLUDED_PARTS = {"build", "_build"}

CALL = re.compile(r"\bassume_init\s*\(")
FUNCTION = re.compile(r"^\s*(?:private\s+)?(?:noinline\s+)?fn\s+(\w+)", re.M)
LISTED = re.compile(r"`((?:kernel|linux_user)/[\w./-]+\.tkb):(\w+)`")


@per_file
def site_functions(text):
    """Names of the functions whose code (not comments) calls assume_init.
    A file that never spells it is skipped before the comment strip."""
    if "assume_init" not in text:
        return frozenset()
    code = code_only(text)
    starts = [(m.start(), m.group(1)) for m in FUNCTION.finditer(code)]
    found = set()
    for match in CALL.finditer(code):
        owner = "<top level>"
        for start, name in starts:
            if start > match.start():
                break
            owner = name
        found.add(owner)
    return frozenset(found)


def listed_sites(markdown):
    return frozenset((m.group(1), m.group(2)) for m in LISTED.finditer(markdown))


def problems_in(files, markdown):
    """files: {relative path: text}; markdown: TRUSTED_BASE.md's text."""
    problems = []
    actual = {(path, name) for path, text in files.items()
              for name in site_functions(text)}
    listed = listed_sites(markdown)
    for path, name in sorted(actual - listed):
        problems.append(f"{path}: {name} calls assume_init but TRUSTED_BASE.md "
                        f"does not list `{path}:{name}` with the fact it trusts")
    for path, name in sorted(listed - actual):
        problems.append(f"TRUSTED_BASE.md lists `{path}:{name}`, which no "
                        "longer calls assume_init; remove the stale entry")
    return problems


def source_files():
    files = {}
    for tree in TREES:
        for path in (ROOT / tree).rglob("*.tkb"):
            relative = path.relative_to(ROOT)
            if EXCLUDED_PARTS & set(relative.parts):
                continue
            files[str(relative)] = path.read_text(encoding="utf-8")
    return files


def main():
    files = source_files()
    markdown = TRUSTED_BASE.read_text(encoding="utf-8")
    problems = problems_in(files, markdown)
    for problem in problems:
        print(f"ERROR\tassume-init-sites: {problem}")
    if problems:
        print("FAIL assume-init-sites: assume_init sites and TRUSTED_BASE.md disagree")
        return 1
    report_pass("assume-init-sites",
                f"{len(files)} Takibi files scanned; every assume_init site "
                "is listed in TRUSTED_BASE.md and every listing is live",
                files=len(files), sites=len(listed_sites(markdown)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
