#!/usr/bin/env python3
"""Controls for check_invariant_stop_sites.py (GitHub issue #1031 slice 1):
a planted stop in a function with no row, a grown count, a stale row, an
unknown class and a ladder row without an issue are refused; a comment-only
mention and a definition are ignored; the real tree and a planted stop with
its row are accepted."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_invariant_stop_sites as check  # noqa: E402
from control_patch import replace_once  # noqa: E402
from pass_line import report_pass  # noqa: E402

FILE = "kernel/kernel/syscall.tkb"
ROW = f"{FILE}\tplanted_stop\tunmodelled\t1\t-\t-\tcontrol\n"


def refused(problems):
    return bool(problems)


def accepted(problems):
    return not problems


def main():
    files = check.source_files()
    tsv = check.LIST.read_text(encoding="utf-8")
    planted = "\nfn planted_stop() {\n    kernel_invariant_stop();\n}\n"
    grown = ("\nfn kernel_syscall_migrate_return_extra() {}\n")
    comment = ("\n// fn planted_comment() { kernel_invariant_stop(); }\n"
               "/* kernel_invariant_stop_with_frame(f); */\n"
               "fn kernel_invariant_stop() {}\n")
    # One more stop inside a listed function (kernel_syscall_migrate_return
    # has one row of 1).
    anchor = ('el0_context_retry_syscall(frame);\n'
              '    if (kernel_process_migrate_current(frame) == false) {')
    exec_grown = replace_once(files[FILE], anchor,
                              anchor + " kernel_invariant_stop();", FILE)
    cases = {
        "a stop in a function with no row is refused":
            (refused, {**files, FILE: files[FILE] + planted}, tsv),
        "a grown count in a listed function is refused":
            (refused, {**files, FILE: exec_grown}, tsv),
        "a stale row is refused":
            (refused, files, tsv + ROW),
        "an unknown class is refused":
            (refused, {**files, FILE: files[FILE] + planted},
             tsv + ROW.replace("unmodelled", "tolerated")),
        "a ladder row without an issue is refused":
            (refused, {**files, FILE: files[FILE] + planted},
             tsv + ROW.replace("unmodelled", "ladder")),
        "a comment-only mention and a definition are ignored":
            (accepted, {**files, FILE: files[FILE] + comment + grown}, tsv),
        "the real tree is accepted":
            (accepted, files, tsv),
        "a planted stop with its row is accepted":
            (accepted, {**files, FILE: files[FILE] + planted}, tsv + ROW),
    }
    failures = []
    for label, (verdict, tree, text) in cases.items():
        result = check.problems_in(tree, text)
        if not verdict(result):
            failures.append(f"{label}: got {result}")
    for failure in failures:
        print(f"ERROR\tinvariant-stop-sites-controls: {failure}")
    if failures:
        print("FAIL invariant-stop-sites-controls")
        return 1
    report_pass("invariant-stop-sites-controls",
                "unrowed stop, grown count, stale row, unknown class and "
                "issueless ladder row refused; comment and definition "
                "ignored; real tree and rowed plant accepted",
                cases=len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
