#!/usr/bin/env python3
"""Controls for check_assume_init_sites.py (GitHub issue #764): an unlisted
site and a stale listing are refused; a comment-only mention is ignored; the
real tree and a planted listed site are accepted (the real tree has no
site since GitHub issue #974)."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_assume_init_sites as check  # noqa: E402
from pass_line import report_pass  # noqa: E402

FILE = "kernel/kernel/syscall.tkb"


def refused(problems):
    return bool(problems)


def accepted(problems):
    return not problems


def main():
    files = check.source_files()
    markdown = check.TRUSTED_BASE.read_text(encoding="utf-8")
    planted = ("\nfn planted_view(b: [u8; 4]) {\n"
               "    unsafe { assume_init(b as []u8); }\n}\n")
    comment = ("\n// fn planted_comment() { assume_init(y); }\n"
               "/* unsafe { assume_init(z); } */\n")
    cases = {
        "an unlisted site is refused":
            (refused, {**files, FILE: files[FILE] + planted}, markdown),
        "a stale listing is refused":
            (refused, files, markdown + f"\n`{FILE}:planted_gone`\n"),
        "a comment-only mention is ignored":
            (accepted, {**files, FILE: files[FILE] + comment}, markdown),
        "the real tree is accepted":
            (accepted, files, markdown),
        "a listed site is accepted":
            (accepted, {**files, FILE: files[FILE] + planted},
             markdown + f"\n`{FILE}:planted_view`\n"),
    }
    failures = []
    for label, (verdict, tree, md) in cases.items():
        result = check.problems_in(tree, md)
        if not verdict(result):
            failures.append(f"{label}: got {result}")
    for failure in failures:
        print(f"ERROR\tassume-init-sites-controls: {failure}")
    if failures:
        print("FAIL assume-init-sites-controls")
        return 1
    report_pass("assume-init-sites-controls",
                "unlisted site and stale listing refused, comment-only "
                "mention ignored, real tree and listed site accepted",
                cases=len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
