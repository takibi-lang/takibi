#!/usr/bin/env python3
"""Build a source overlay for the issue #829 per-CPU wake negative control."""

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


# The two sources the control rewrites; every other input is a symlink.
OVERLAID = {"arch/arm64/kernel/secondary.tkb", "arch/arm64/kernel/timer.tkb"}


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

    # Mirror directories and symlink every input except the secondary-tick
    # source, whose single intended transformation drops its own wake.
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
            if relative_file.as_posix() in OVERLAID:
                continue
            target.symlink_to(current_path / name)

    for relative in sorted(OVERLAID):
        (overlay_kernel / relative).write_text(
            (source_kernel / relative).read_text(encoding="ascii"),
            encoding="ascii",
        )
    # GitHub issue #829: the kernel before per-CPU tick-wake lists. A
    # secondary's tick wakes nothing, and core 0's tick wakes the due
    # sleepers of every core -- the old single walker, over the same lists.
    replace_once(
        overlay_kernel / "arch/arm64/kernel/secondary.tkb",
        "    kernel_process_tick_wake_if_due();\n",
        # Still referenced, so the unused-function check is not what fails.
        "    if (KERNEL_STALL_PROBES == 2) { kernel_process_tick_wake_if_due(); }\n",
    )
    replace_once(
        overlay_kernel / "arch/arm64/kernel/timer.tkb",
        "    kernel_process_tick_wake(guard);\n",
        "    if (KERNEL_STALL_PROBES == 2) { kernel_process_tick_wake(guard); }\n"
        "    for every_core: usize in 0..<KERNEL_MAX_CORES {\n"
        "        if (every_core < KERNEL_MAX_CORES) {\n"
        "            let walked: {0..<KERNEL_MAX_CORES as usize} = every_core;\n"
        "            kernel_process_tick_wake_scan(guard, walked, read_cntpct() as usize);\n"
        "        }\n"
        "    }\n",
    )


if __name__ == "__main__":
    main()
