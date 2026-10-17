#!/usr/bin/env python3
"""Controls for check_page_freelist_rebuild_callers.py.

The pre-#771 shape -- page_alloc_contiguous_locked calling the rebuild per
run -- must be refused naming that caller; the install-only shape passes,
and a commented-out call does not count. The check runs as a subprocess on
each mutant file.

Exit code only (0 = pass, 1 = fail).
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from pass_line import report_pass

CHECK = Path(__file__).resolve().parent / "check_page_freelist_rebuild_callers.py"

BAD = """private fn page_alloc_contiguous_locked(count: usize) {
    if (pool.runtime_applied) {
        page_runtime_freelist_rebuild(pool, metas, extents);
    }
}
private fn page_allocator_fill_metadata() -> bool {
    page_runtime_freelist_rebuild(pool, metas, extents);
}
"""

GOOD = """private fn page_allocator_fill_metadata() -> bool {
    page_runtime_freelist_rebuild(pool, metas, extents);
}
fn page_run_free() {
    // page_runtime_freelist_rebuild(pool, metas, extents);
}
"""


def run(text):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "page.tkb"
        path.write_text(text, encoding="ascii")
        return subprocess.run([sys.executable, str(CHECK), str(path)],
                              capture_output=True, text=True)


def main():
    bad = run(BAD)
    if bad.returncode == 0 or "called from page_alloc_contiguous_locked" not in bad.stdout:
        print("FAIL page-freelist-rebuild controls: per-run rebuild not refused:\n" + bad.stdout)
        return 1
    good = run(GOOD)
    if good.returncode != 0:
        print("FAIL page-freelist-rebuild controls: install-only shape refused:\n" + good.stdout)
        return 1
    report_pass("page-freelist-rebuild controls",
                "per-run rebuild refused, install-only and comments accepted",
                refused_lines=bad.stdout.count("FAIL"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
