"""Shared runner of the real-kernel overlay buildchecks (GitHub issue #915).

A buildcheck case appends a control to one kernel source and type-checks the
whole QEMU kernel list against it. Run one after another, the cases of
buildcheck_backing_exists.py were the longest allcheck lane (447 s) without
using any QEMU. The cases are independent, so they run on a bounded pool,
each worker in a symlinked overlay of its own, and their results come back in
case order so a failure reads as it did serially.
"""

from __future__ import annotations

import concurrent.futures
import os
from pathlib import Path
import queue
import subprocess
import tempfile
from typing import Callable, Sequence, TypeVar

Case = TypeVar("Case")


def overlay_jobs(case_count: int) -> int:
    """How many cases compile at once. The three overlay buildchecks run
    beside each other (#820), so one check takes at most a quarter of the
    host threads; TAKIBI_BUILDCHECK_JOBS overrides it, and 1 is the serial
    run."""
    configured = os.environ.get("TAKIBI_BUILDCHECK_JOBS")
    if configured:
        jobs = int(configured)
        if jobs < 1:
            raise ValueError(f"TAKIBI_BUILDCHECK_JOBS must be at least 1, got {configured}")
    else:
        jobs = max(1, (os.cpu_count() or 1) // 4)
    return max(1, min(jobs, case_count))


def symlink_kernel_tree(repo: Path, overlay: Path) -> None:
    """Symlink every kernel file into `overlay` one by one, so replacing one
    link with an edited copy cannot touch the real tree. Generated kernel
    files remain available after kernelbuild."""
    for original in (repo / "kernel").rglob("*"):
        target = overlay / original.relative_to(repo)
        if original.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        elif original.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(original)


def run_overlay_cases(
        repo: Path, prefix: str, cases: Sequence[Case],
        edit: Callable[[Case], tuple[Path, str]],
        command: Callable[[Path], list[str]],
        judge: Callable[[Case, subprocess.CompletedProcess], str | None]) -> list[str | None]:
    """Compile every case and return, in case order, judge's failure message
    or None. `edit(case)` names the repo-relative file the case replaces and
    its whole new text; `command(overlay)` is the compiler command run in the
    overlay."""
    jobs = overlay_jobs(len(cases))
    with tempfile.TemporaryDirectory(prefix=prefix) as tmp:
        overlays: queue.Queue[Path] = queue.Queue()
        for index in range(jobs):
            overlay = Path(tmp) / str(index)
            symlink_kernel_tree(repo, overlay)
            overlays.put(overlay)

        def run_case(case: Case) -> str | None:
            edited, text = edit(case)
            overlay = overlays.get()
            target = overlay / edited
            try:
                target.unlink()
                target.write_text(text, encoding="ascii")
                result = subprocess.run(command(overlay), cwd=overlay,
                                        capture_output=True, text=True, check=False)
            finally:
                target.unlink(missing_ok=True)
                target.symlink_to(repo / edited)
                overlays.put(overlay)
            return judge(case, result)

        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            return list(pool.map(run_case, cases))
