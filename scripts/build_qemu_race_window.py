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
# (file, its text, what --revert leaves in its place). A window whose defect
# the fix removed by construction lists several edits: --revert then puts back
# the write that made the defect possible as well as removing the check.
WINDOWS = {
    # A completed peer can re-enter before the primary disarms the phase.
    # Holding the primary here exposes the old restart-from-zero loop.
    "678": {
        "spin": ("kernel/freelist_contention_evidence.tkb",
                 "    // With per-round rendezvous this is the secondary completion count at\n"
                 "    // the instant the primary finishes, not a scheduler-granularity metric.\n",
                 False),
        "check": ("kernel/freelist_contention_evidence.tkb",
                  '    // The idle loop may enter again before the primary disarms this phase.\n'
                  "    // Keep the round in the phase's published count, not a fresh local loop:\n"
                  '    // an old rendezvous sequence must never authorize another allocation.\n'
                  '    while (atomic_word_load(freelist_probe_secondary_address()) <\n'
                  '               FREELIST_CONTENTION_ROUNDS &&\n'
                  '           atomic_word_load(freelist_probe_armed_address()) == 1) {\n'
                  '        let sequence: usize =\n'
                  '            atomic_word_load(freelist_probe_secondary_address()) + 1;\n'
                  '        if (freelist_probe_cycle(false, sequence)) {\n'
                  '            atomic_word_fetch_add(freelist_probe_secondary_address(), 1);\n'
                  '        }\n'
                  '    }\n',
                  '    for round: usize in 0..<FREELIST_CONTENTION_ROUNDS {\n'
                  '        if (atomic_word_load(freelist_probe_armed_address()) == 1) {\n'
                  '            if (freelist_probe_cycle(false, round + 1)) {\n'
                  '                atomic_word_fetch_add(freelist_probe_secondary_address(), 1);\n'
                  '            }\n'
                  '        }\n'
                  '    }\n'),
    },
    # Deliberately never open CPU 0. The finite child may finish on CPU 1,
    # but its parent must refuse wait4 without a timer leave observation.
    "705-missed-arrival": {
        "spin": None,
        "check": [("kernel/process.tkb",
                   "        scheduled_process_set_affinity_mask(guard, slot, 1);\n",
                   "        scheduled_process_set_affinity_mask(guard, slot, 2);\n")],
    },
    # The actual timer no-successor leave must be necessary to spread's
    # observation. Ordinary syscall migration after its finite spin cannot
    # satisfy this control; it must finish with the missing-ToIdle diagnosis.
    "705": {
        "spin": None,
        "check": [("kernel/process.tkb",
                   "    if (kernel_process_tick_leave_excluded(current)) {\n",
                   "    if (false) {\n")],
    },
    # GitHub issue #609: a peer published its process Blocked in wait4 and
    # still stands on that process's stack until its idle entry releases
    # it. A child exiting on core 0 meanwhile must not start the parent on
    # that stack; kernel_process_child_exit's direct start asks
    # scheduled_process_start_check, whose owner read is the check.
    "609": {
        "spin": ("kernel/process.tkb",
                 "fn kernel_process_stack_idle_blocked() {\n"
                 "    let core: usize = cpu_id();\n",
                 True),
        "check": ("kernel/process.tkb",
                  "    if (scheduled_process_record_locked(guard, owner.pool_index).stack_owner_cpu !=\n"
                  "            PROCESS_STACK_UNOWNED) {\n"
                  "        return ScheduledProcessStartCheck::Standing(state);\n"
                  "    }\n"
                  "    scheduled_process_state_drop(state);\n"
                  "    return ScheduledProcessStartCheck::Startable(\n"
                  "        scheduled_process_startable_state(owner));\n"
                  "}\n"
                  "\n"
                  "// The same for a process this CPU itself stands on:",
                  "    scheduled_process_state_drop(state);\n"
                  "    return ScheduledProcessStartCheck::Startable(\n"
                  "        scheduled_process_startable_state(owner));\n"
                  "}\n"
                  "\n"
                  "// The same for a process this CPU itself stands on:"),
    },
    # GitHub issue #603: wait4 has recorded ChildExit and chosen to block,
    # and the child exits before the block is published. The block is
    # abandoned and the syscall rerun, and kernel_syscall_block_return must
    # drop the marker, or the process is later Ready and refused everywhere.
    "603": {
        "spin": ("kernel/process.tkb",
                 "fn kernel_process_block_wait4(current_authority: ProcessCurrent[current_process, ProcessState::Running], current: borrow FrameRef[process])\n"
                 "        -> BlockSwitch {\n",
                 False),
        # wait4's decision lives in pending_block_reason now, and only a
        # block publishes a wait, so an abandoned block leaves nothing. The
        # reverted kernel publishes the decision again, as the record's
        # single wait_reason field did, and drops the clear.
        "check": [
            ("kernel/syscall.tkb",
             "            if (reason == ProcessWaitReason::ChildExit) {\n"
             "                kernel_process_current_set_pending_block_locked(\n"
             "                    retry_guard, ProcessWaitReason::None, 0);\n"
             "            }\n",
             ""),
            ("kernel/process.tkb",
             "            .pending_block_reason = reason;\n",
             "            .pending_block_reason = reason;\n"
             "        // The reverted kernel says it is Blocked, which it is not.\n"
             "        match process_wait_publish(\n"
             "                &scheduled_process_record_current(current_authority).wait, reason,\n"
             "                ProcessSlotState::Blocked) {\n"
             "            ProcessWaitPublish::Published => {}\n"
             "            ProcessWaitPublish::Refused => {}\n"
             "        }\n"),
        ],
    },
    # GitHub issue #635: no window and no spin -- a control only. A terminal
    # settings change that makes queued bytes readable must wake a reader
    # already asleep in a read. The reverted kernel drops that wake, so the
    # reader sleeps on and the kernel's own bounded wait reports it. Only the
    # reverted kernel is built or run for this entry.
    "635": {
        "spin": None,
        "check": ("kernel/syscall.tkb",
                  "            if (kernel_uart_rx_pending()) { "
                  "kernel_process_terminal_settings_wake(guard); }\n",
                  ""),
    },
    # GitHub issue #633: wait4 has reaped a zombie and is about to return
    # its pid. A sibling exiting on another CPU meanwhile writes the
    # parent's last_child_pid (now last_reaped_pid). Returning the pid reaped is the check; the
    # reverted kernel returns last_child_pid read afterwards, as before,
    # and the shell waits for good for the child it was never told about.
    "633": {
        "spin": ("kernel/syscall.tkb",
                 "                let reaped_status: usize =\n"
                 "                    kernel_process_current_reap_pid(zombie_pid);\n",
                 False),
        # A child's exit no longer writes its parent's record, so the
        # reverted kernel also puts that write back.
        "check": [
            ("kernel/syscall.tkb",
             "                return syscall_finish_current(frame, SyscallAction::Resume(zombie_pid), current_authority);\n",
             "                return syscall_finish_current(frame, SyscallAction::Resume(\n"
             "                    kernel_process_last_reaped_pid(current_authority)), current_authority);\n"),
            ("kernel/process.tkb",
             "    execution_state[execution_cpu_index()].last_exited_child_pid =\n"
             "        scheduled_process_pid_of_handle(child);\n",
             "    execution_state[execution_cpu_index()].last_exited_child_pid =\n"
             "        scheduled_process_pid_of_handle(child);\n"
             "    let reverted_guard = process_run_guard_forge_unlocked();\n"
             "    scheduled_process_record_of_locked(reverted_guard, parent).last_reaped_pid =\n"
             "        scheduled_process_pid_of_handle(child);\n"
             "    process_run_guard_discard_unlocked(reverted_guard);\n"),
        ],
    },
}

# Delay each real secondary probe entry with IRQs masked: the host counter
# advances for 750 ms while this participant takes no ticks. This is a
# deterministic approximation of a descheduled vCPU, not cache/timing proof.
PROBE_ENTRIES = (
    "pool_contention", "freelist_contention", "page_contention",
    "asid_contention", "fd_refcount_contention", "pid_contention",
    "tag_contention", "schedule_contention", "occupancy_drain",
    "console_contention", "init_once_contention", "tcp_connection_contention",
    "world_stop_peer_probe", "pool_walk_contention", "ext2_mutation_contention",
    "signal_contention",
)
PROBE_ENTRY_DELAY = (
    "                    let saved_probe_irq: usize = mutex_irq_save();\n"
    "                    let delayed_probe_entry: i64 = read_cntpct();\n"
    "                    while (read_cntpct() - delayed_probe_entry <\n"
    "                           (read_cntfrq() >> 1) + (read_cntfrq() >> 2)) {}\n"
    "                    mutex_irq_restore(saved_probe_irq);\n"
)
WINDOWS["651"] = {
    "spin": None,
    "prepare": [
        ("arch/arm64/kernel/secondary.tkb",
         f"                    {name}_secondary_run();\n",
         PROBE_ENTRY_DELAY + f"                    {name}_secondary_run();\n")
        for name in PROBE_ENTRIES
    ],
    "check": ('lib/peer_tick_window.tkb',
 '    return kernel_tick_count_of(window.peer) - window.ticks_start.value <\n'
 '               window.tick_budget.ticks && wall_emergency_open(window.wall_start);\n',
 '    return read_cntpct() - window.wall_start.value <\n'
 '               (read_cntfrq() >> 6) * (window.tick_budget.ticks as i64);\n'),
}
WINDOWS["651-no-peer"] = {
    "spin": None,
    "check": [
        ("arch/arm64/kernel/secondary.tkb",
         f"                    {name}_secondary_run();\n",
         f"                    if (cpu_id() == 0) {{ {name}_secondary_run(); }}\n")
        for name in PROBE_ENTRIES
    ] + [('kernel/occupancy_drain_evidence.tkb',
  '    match world_stop_begin(\n'
  '            &kernel_world_stop, 2, WORLD_STOP_PROBE_SPINS) {\n',
  '    let chosen_stop = match world_stop_resume_control {\n'
  '        0 => { world_stop_begin_nonack_probe(\n'
  '            &kernel_world_stop, 2, WORLD_STOP_PROBE_SPINS) }\n'
  '        _ => { world_stop_begin(\n'
  '            &kernel_world_stop, 2, WORLD_STOP_PROBE_SPINS) }\n'
  '    };\n'
  '    match chosen_stop {\n'),
 ('kernel/occupancy_drain_evidence.tkb',
  'fn world_stop_probe() -> bool !{unsafe} {\n',
  'let mut world_stop_resume_control: usize;\n'
  'let mut world_stop_resume_control_before: usize;\n'
  'let mut world_stop_resume_control_observed: usize;\n'
  'fn world_stop_probe() -> bool !{unsafe} {\n'
  '    world_stop_resume_control_before = secondary_tick_value();\n'
  '    if (world_stop_resume_control == 1) {\n'
  '        while (secondary_tick_value() == world_stop_resume_control_before) {}\n'
  '    }\n'),
 ('lib/peer_tick_window.tkb',
  'fn peer_tick_stamp_changed(',
  '// Overlay-only raw mint for the frozen observation and deliberately wrong '
  'baseline.\n'
  'fn peer_tick_stamp_control(peer: {0..<KERNEL_MAX_CORES as usize} @ p,\n'
  '                           raw: usize) -> PeerTickStamp[p] {\n'
  '    let mut stamp: PeerTickStamp[p] = { raw }; return stamp;\n'
  '}\n'
  'fn peer_tick_stamp_changed('),
 ('lib/occupancy.tkb',
  '    let mut baseline: PeerTickStamp[p] = peer_tick_stamp(peer);\n',
  '    world_stop_resume_control_observed = kernel_tick_count_of(peer);\n'
  '    let mut baseline: PeerTickStamp[p] = peer_tick_stamp(peer);\n'),
 ('lib/occupancy.tkb',
  '    let mut now: PeerTickStamp[p] = peer_tick_stamp(ticket.core);\n',
  '    let mut now: PeerTickStamp[p] = peer_tick_stamp(ticket.core);\n'
  '    if (world_stop_resume_control == 1) {\n'
  '        now = peer_tick_stamp_control(ticket.core, '
  'world_stop_resume_control_observed);\n'
  '    }\n'),
 ('kernel/signal_contention_evidence.tkb',
  'private fn signal_probe_round(round: usize, locked: bool) -> usize\n'
  '        !{unsafe} {\n',
  'let mut signal_round_control: usize;\n'
  'private fn signal_probe_round(round: usize, locked: bool) -> usize\n'
  '        !{unsafe} {\n'
  '    signal_round_control = signal_round_control + 1;\n'),
 ('init/contention_probes.tkb',
  '        kernel_boot_log("world stop from a peer: failed\\n");\n    }\n}\n',
  '        kernel_boot_log("world stop from a peer: failed\\n");\n'
  '    }\n'
  '    world_stop_resume_control = 1;\n'
  '    if (world_stop_probe() == false) {\n'
  '        kernel_boot_log("world stop resume control: refused\\n");\n'
  '    } else {\n'
  '        kernel_boot_log("world stop resume control: admitted\\n");\n'
  '    }\n'
  '    kernel_boot_log("signal phase control attempts: ");\n'
  '    uart_put_udec(signal_round_control);\n'
  '    kernel_boot_log("\\n");\n'
  '    kernel_boot_log("probe-ticks: missing-peer controls complete\\n");\n'
  '    while (true) { wfi(); }\n'
  '}\n')],
}
WINDOWS["651-resume-old"] = {
    "spin": None,
    "check": WINDOWS["651-no-peer"]["check"] + [('lib/occupancy.tkb',
  '    let mut baseline: PeerTickStamp[p] = peer_tick_stamp(peer);\n',
  '    let mut baseline: PeerTickStamp[p] = peer_tick_stamp_control(\n'
  '        peer, world_stop_resume_control_before);\n'),
 ('kernel/signal_contention_evidence.tkb',
  '        if (missed == false) {\n'
  '            match signal_probe_round(index + 1, locked == 1) {\n'
  '                0 => {}\n'
  '                1 => { lost = lost + 1; }\n'
  '                _ => { missed = true; }\n'
  '            }\n'
  '        }\n',
  '        match signal_probe_round(index + 1, locked == 1) {\n'
  '            0 => {}\n'
  '            1 => { lost = lost + 1; }\n'
  '            _ => { missed = true; }\n'
  '        }\n')],
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
    checks = window["check"]
    if isinstance(checks, tuple):
        checks = [checks]
    preparation = window.get("prepare", [])
    edited_files = {check_file for check_file, _, _ in checks + preparation}
    if window["spin"] is not None:
        spin_file, anchor, peer_only = window["spin"]
        edited_files.add(spin_file)
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
    if window["spin"] is not None:
        replace_once(overlay_kernel / spin_file, anchor,
                     anchor + spin(args[2], peer_only))
    for file, before, after in preparation:
        replace_once(overlay_kernel / file, before, after)
    if revert:
        for check_file, check, reverted in checks:
            replace_once(overlay_kernel / check_file, check, reverted)


if __name__ == "__main__":
    main()
