#!/usr/bin/env python3
"""Build a source overlay for the issue #587 lockless-wake negative control."""

import os
from pathlib import Path
import shutil
import sys


def replace_once(path: Path, before: str, after: str) -> None:
    source = path.read_text(encoding="ascii")
    count = source.count(before)
    if count != 1:
        raise SystemExit(f"expected exactly one control edit in {path}, found {count}")
    path.write_text(source.replace(before, after), encoding="ascii")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: build_qemu_net_wake_control.py KERNEL_ROOT OVERLAY_ROOT")
    source_root = Path(sys.argv[1]).resolve()
    overlay_root = Path(sys.argv[2]).resolve()
    source_kernel = source_root / "kernel"
    overlay_kernel = overlay_root / "kernel"
    if overlay_kernel.exists():
        shutil.rmtree(overlay_kernel)
    overlay_kernel.mkdir(parents=True)

    # Mirror directories and symlink every input except the timer source whose
    # single intended transformation removes protection from the NetRx scan.
    for current, directories, files in os.walk(source_kernel):
        current_path = Path(current)
        relative = current_path.relative_to(source_kernel)
        target_dir = overlay_kernel / relative
        target_dir.mkdir(parents=True, exist_ok=True)
        # Build products include this overlay itself; they are output paths,
        # not compiler inputs, and traversing them would recurse forever.
        directories[:] = [name for name in directories
                          if name not in {".git", "build"}]
        for directory in directories:
            (target_dir / directory).mkdir(exist_ok=True)
        for name in files:
            relative_file = (current_path / name).relative_to(source_kernel)
            target = overlay_kernel / relative_file
            if relative_file.as_posix() == "arch/arm64/kernel/timer.tkb":
                continue
            target.symlink_to(current_path / name)

    timer_path = overlay_kernel / "arch/arm64/kernel/timer.tkb"
    timer_path.write_text(
        (source_kernel / "arch/arm64/kernel/timer.tkb").read_text(encoding="ascii"),
        encoding="ascii",
    )
    replace_once(
        timer_path,
        "    let guard = process_run_lock();\n"
        "    kernel_process_net_wake_all(guard);\n"
        "    kernel_process_deadline_wake_all(guard);",
        "    kernel_process_net_wake_scan();\n"
        "    let guard = process_run_lock();\n"
        "    kernel_process_deadline_wake_all(guard);",
    )


if __name__ == "__main__":
    main()
