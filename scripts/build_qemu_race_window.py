#!/usr/bin/env python3
"""Build a source overlay that widens one named race window (GitHub #615).

The multicore route's decisive defects are windows between two critical
sections, and QEMU crosses them by chance: #609's shared-stack window showed
in about one run in five, and with its fix reverted it reproduced once in
ten. This overlay makes one window wide enough to be crossed on every run,
so a check whose removal the window exposes can be made to fail every time.

usage: build_qemu_race_window.py KERNEL_ROOT OVERLAY_ROOT WINDOW [--revert]

WINDOW names an entry in WINDOWS. The overlay inserts a spin at the window's
opening. With --revert it also removes the check the window is there to
exercise, which is the negative control. The ordinary source never contains
the spin, so no release or debug build can: the overlay is the only place it
exists, and scripts/check_race_window_overlay_only.py refuses it in kernel/.
"""

import os
from pathlib import Path
import shutil
import sys


def spin(label: str, peer_only: bool) -> str:
    # About 31 ms (the counter frequency over 32). A window that opens on a
    # peer spins on a peer only, so core 0's boot fixtures are not slowed.
    guard = "cpu_id() != 0" if peer_only else "true"
    return (
        f"    // race window {label} (scripts/build_qemu_race_window.py)\n"
        f"    if ({guard}) {{\n"
        "        let race_window_start: i64 = read_cntpct();\n"
        "        while (read_cntpct() - race_window_start <\n"
        "               (read_cntfrq() >> 5)) {}\n"
        "    }\n"
    )


# name -> the spin (file, the text it follows, peer only) and the check
# (file, its text, what --revert leaves in its place).
WINDOWS = {
    # GitHub issue #609: a peer published its process Blocked in wait4 and
    # still stands on that process's stack until its idle entry releases
    # it. A child exiting on core 0 meanwhile must not start the parent on
    # that stack; kernel_process_child_exit's direct start checks the owner.
    "609": {
        "spin": ("kernel/process.tkb",
                 "fn kernel_process_stack_idle_blocked() {\n"
                 "    let core: usize = cpu_id();\n",
                 True),
        "check": ("kernel/process.tkb",
                  "                        if (kernel_process_cpu_allows_slot(\n"
                  "                                cpu_id(), parent.pool_index) &&\n"
                  "                            scheduled_process_record_of(parent)\n"
                  "                                .stack_owner_cpu == PROCESS_STACK_UNOWNED) {\n",
                  "                        if (kernel_process_cpu_allows_slot(\n"
                  "                                cpu_id(), parent.pool_index)) {\n"),
    },
    # GitHub issue #603: wait4 has recorded ChildExit and chosen to block,
    # and the child exits before the block is published. The block is
    # abandoned and the syscall rerun, and kernel_syscall_block_return must
    # drop the marker, or the process is later Ready and refused everywhere.
    "603": {
        "spin": ("kernel/process.tkb",
                 "fn kernel_process_block_wait4(current_sp: usize) -> usize {\n",
                 False),
        "check": ("kernel/syscall.tkb",
                  "        if (kernel_process_current_pending_block_reason() ==\n"
                  "                ProcessWaitReason::ChildExit) {\n"
                  "            kernel_process_current_set_pending_block(\n"
                  "                ProcessWaitReason::None, 0);\n"
                  "        }\n",
                  ""),
    },
}


def replace_once(path: Path, before: str, after: str) -> None:
    source = path.read_text(encoding="ascii")
    count = source.count(before)
    if count != 1:
        raise SystemExit(
            f"expected exactly one race-window edit in {path}, found {count}")
    path.write_text(source.replace(before, after), encoding="ascii")


def main() -> None:
    args = sys.argv[1:]
    revert = "--revert" in args
    args = [arg for arg in args if arg != "--revert"]
    if len(args) != 3 or args[2] not in WINDOWS:
        raise SystemExit("usage: build_qemu_race_window.py KERNEL_ROOT "
                         f"OVERLAY_ROOT {{{','.join(WINDOWS)}}} [--revert]")
    source_root = Path(args[0]).resolve()
    overlay_root = Path(args[1]).resolve()
    window = WINDOWS[args[2]]
    spin_file, anchor, peer_only = window["spin"]
    check_file, check, reverted = window["check"]
    edited_files = {spin_file, check_file}
    source_kernel = source_root / "kernel"
    overlay_kernel = overlay_root / "kernel"
    if overlay_kernel.exists():
        shutil.rmtree(overlay_kernel)
    overlay_kernel.mkdir(parents=True)

    # Mirror the tree as symlinks, except the files this window edits.
    for current, directories, files in os.walk(source_kernel):
        current_path = Path(current)
        target_dir = overlay_kernel / current_path.relative_to(source_kernel)
        target_dir.mkdir(parents=True, exist_ok=True)
        # Build products include overlays themselves; they are output paths,
        # not compiler inputs, and traversing them would recurse forever.
        directories[:] = [name for name in directories
                          if name not in {".git", "build"}]
        for directory in directories:
            (target_dir / directory).mkdir(exist_ok=True)
        for name in files:
            relative_file = (current_path / name).relative_to(source_kernel)
            if relative_file.as_posix() in edited_files:
                continue
            (overlay_kernel / relative_file).symlink_to(current_path / name)

    for relative in edited_files:
        (overlay_kernel / relative).write_text(
            (source_kernel / relative).read_text(encoding="ascii"),
            encoding="ascii")
    replace_once(overlay_kernel / spin_file, anchor,
                 anchor + spin(args[2], peer_only))
    if revert:
        replace_once(overlay_kernel / check_file, check, reverted)


if __name__ == "__main__":
    main()
