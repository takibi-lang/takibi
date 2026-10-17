#!/usr/bin/env python3
"""Fast-gate members do not spawn processes, except git or reviewed ones.

GitHub issue #808. Two lands in a row failed on a fast-gate member over the
10 s bound under the parallel allcheck (check_lock_rank_wrappers_controls,
then check_wont_compile_catalog_controls). The second waited on child
processes: each control started a Python or compiler child, and a loaded host
stretched every wait. The gate's own rule is that a member that waits
belongs in the slow lane, so the members that spawned children and measured
0.5 s or more standalone were renamed slowcheck_*.

This keeps the class out. In every scripts/check_*.py, a call to
subprocess.run/call/check_call/check_output/Popen, os.system or os.spawn* /
os.exec* whose argv is not a literal list starting with "git" is an error,
unless the file is listed in REVIEWED with what it spawns and why it stays
fast. `git ls-files`-style calls read the index and do not wait on work.

Limits (lexical): a spawn hidden in an imported helper module is not seen,
and shell members (check_*.sh) are not checked; both stay review.

Controls: scripts/check_fast_gate_no_spawn_controls.py.
"""

import ast
import pathlib
import sys

from pass_line import report_pass
from source_scan import per_file

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
SPAWN_SUBPROCESS = {"run", "call", "check_call", "check_output", "Popen"}
SPAWN_OS = {"system", "popen"}

# member -> what it spawns and why it stays in the fast gate. Reviewed only;
# each measured under 0.5 s standalone on 2026-10-17 (#808).
SHORT_CHILDREN = "a few short Python children over fixtures, measured under 0.5 s standalone"
REVIEWED = {
    "check_known_intermittents_controls.py": SHORT_CHILDREN,
    "check_measure_kernel_tcp_throughput_controls.py": SHORT_CHILDREN,
    "check_kernel_memory_map_controls.py": SHORT_CHILDREN,
    "check_lane_artifact_root_controls.py": SHORT_CHILDREN,
    "check_slot_proof_dropped_to_index_controls.py": SHORT_CHILDREN,
    "check_affinity_probe_migrates_controls.py": SHORT_CHILDREN,
    "check_documented_counts_controls.py": SHORT_CHILDREN,
    "check_ddb_command_inventory_controls.py": SHORT_CHILDREN,
    "check_xhci_register_offsets_controls.py": SHORT_CHILDREN,
    "check_platform_view_parity_controls.py": SHORT_CHILDREN,
    "check_await_summary_controls.py": SHORT_CHILDREN,
    "check_ddb_wait_reason_names_controls.py": SHORT_CHILDREN,
    "check_boot_log_snapshot_controls.py": SHORT_CHILDREN,
    "check_pool_zero_before_stamp_controls.py": SHORT_CHILDREN,
    "check_no_cursor_reply_controls.py": SHORT_CHILDREN,
    "check_gdb_no_guest_memory_read_controls.py": SHORT_CHILDREN,
    "check_fixed_wait_await_controls.py": SHORT_CHILDREN,
    "check_patch_embedded_image_controls.py": SHORT_CHILDREN,
    "check_gdb_bounded_controls.py": SHORT_CHILDREN,
    "check_elf_symbol_alignment_controls.py": SHORT_CHILDREN,
    "check_race_window_overlay_only_controls.py": SHORT_CHILDREN,
    "check_found_by_policy_controls.py": SHORT_CHILDREN,
    "check_expected_line_endings_controls.py": SHORT_CHILDREN,
    "check_direct_mmio_literals_controls.py": SHORT_CHILDREN,
    "check_rpi5_set_kernel_byte_controls.py": "runs the set-kernel-byte script on a fixture ELF with stub tools, 0.2 s",
    "check_symbolize_ddb_controls.py": "compiles one tiny C file twice with cc (timeout 4 s), 0.3 s",
}


def git_argv(call: ast.Call) -> bool:
    if not call.args:
        return False
    first = call.args[0]
    return (isinstance(first, (ast.List, ast.Tuple)) and first.elts
            and isinstance(first.elts[0], ast.Constant) and first.elts[0].value == "git")


def is_spawn(call: ast.Call) -> bool:
    func = call.func
    if not isinstance(func, ast.Attribute) or not isinstance(func.value, ast.Name):
        return False
    module, name = func.value.id, func.attr
    if module == "subprocess":
        return name in SPAWN_SUBPROCESS
    if module == "os":
        return name in SPAWN_OS or name.startswith(("spawn", "exec"))
    return False


@per_file
def spawn_lines(name: str, text: str):
    """Lines of non-git spawns in one member, cached by content."""
    tree = ast.parse(text, filename=name)
    return tuple(node.lineno for node in ast.walk(tree)
                 if isinstance(node, ast.Call) and is_spawn(node) and not git_argv(node))


def problems(members: dict, reviewed: dict = REVIEWED) -> list:
    """`members` maps a check_*.py file name to its text."""
    found = []
    spawning = set()
    for name, text in sorted(members.items()):
        lines = spawn_lines(name, text)
        if not lines:
            continue
        spawning.add(name)
        if name not in reviewed:
            found.append(f"scripts/{name}:{lines[0]}: fast-gate member spawns a non-git "
                         f"process; a member that waits belongs in the slow lane "
                         f"(rename it slowcheck_*), or list it in REVIEWED with why it "
                         f"stays fast")
    for name in sorted(reviewed):
        if name not in spawning:
            found.append(f"REVIEWED lists {name}, which spawns no non-git process "
                         f"(or is no longer a fast-gate member): stale")
    return found


def members() -> dict:
    return {path.name: path.read_text(encoding="utf-8")
            for path in sorted(SCRIPTS.glob("check_*.py"))}


def main() -> int:
    tree = members()
    found = problems(tree)
    if found:
        for line in found:
            print(f"FAIL fast-gate-no-spawn: {line}", file=sys.stderr)
        return 1
    report_pass("fast-gate-no-spawn",
                f"{len(tree)} fast-gate Python members spawn only git, "
                f"or are reviewed ({len(REVIEWED)})",
                members=len(tree), reviewed=len(REVIEWED))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
