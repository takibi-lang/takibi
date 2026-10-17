#!/usr/bin/env python3
"""Controls for check_page_freelist_rebuild_callers.py.

The pre-#771 shape -- page_alloc_contiguous_locked calling the rebuild per
run -- must be named as a failing caller; the install-only shape passes, and
a commented-out call does not count.

Exit code only (0 = pass, 1 = fail).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_page_freelist_rebuild_callers as check  # noqa: E402

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


def main():
    bad = [f for _, f in check.callers(BAD) if f not in check.ALLOWED]
    good = [f for _, f in check.callers(GOOD) if f not in check.ALLOWED]
    if bad != ["page_alloc_contiguous_locked"]:
        print("FAIL page-freelist-rebuild controls: per-run rebuild not refused: %r" % bad)
        return 1
    if good:
        print("FAIL page-freelist-rebuild controls: install-only shape refused: %r" % good)
        return 1
    print("PASS page-freelist-rebuild controls: per-run rebuild refused, install-only and comments accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
