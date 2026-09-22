#!/usr/bin/env python3
"""Keep the peer-filesystem verdict tied to real cross-CPU exclusion."""

from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent


def sources() -> dict[str, str]:
    names = [
        "kernel/drivers/block/memory.tkb",
        "kernel/kernel/workload_evidence.tkb",
        "kernel/kernel/process.tkb",
        "kernel/arch/arm64/kernel/peer_read.tkb",
        "kernel/tests/common/views/peer_filesystem.expected",
        "kernel/tests/common/views/peer_filesystem.filter",
        "scripts/run_kernel_qemutest.sh",
        "scripts/run_kernel_hwtest_rpi5.sh",
    ]
    return {name: (ROOT / name).read_text() for name in names}


def problems(tree: dict[str, str]) -> list[str]:
    memory = tree["kernel/drivers/block/memory.tkb"]
    evidence = tree["kernel/kernel/workload_evidence.tkb"]
    process = tree["kernel/kernel/process.tkb"]
    payload = tree["kernel/arch/arm64/kernel/peer_read.tkb"]
    expected = tree["kernel/tests/common/views/peer_filesystem.expected"]
    view_filter = tree["kernel/tests/common/views/peer_filesystem.filter"]
    result = []

    lock_shape = (
        "if (task_mutex_trylock(&block_device_lock) == false) {\n"
        "        block_note_call(block_device_waits as []usize);\n"
        "        task_mutex_acquire(&block_device_lock);\n"
        "    }"
    )
    if lock_shape not in memory:
        result.append("device acquisition does not record a failed first try")
    for condition in (
        "block_read_call_count(SECONDARY_CORE_ID) == 0",
        "block_device_wait_count(0) == 0",
        "block_device_wait_count(SECONDARY_CORE_ID) == 0",
    ):
        if condition not in evidence:
            result.append(f"verdict no longer rejects missing {condition}")
    # GitHub issue #581: the reader's placement is its own affinity mask now,
    # not a pair of per-pid branches in the kernel's admission rule. It used
    # to need those because its openat and read were outside the peer-safety
    # table and the table could not admit it; they are in the table, so what
    # holds it on CPU 1 -- and therefore off core 0, which is what makes the
    # device contention two-sided -- is the pin below.
    # The literal pin appears in the console writer too, so the reader's is
    # named by the line that follows only it.
    reader_pin = ("if (peer_pin(peer_cpu) == false) "
                  "{ svc5(EXIT_SYSCALL, 1, 0, 0, 0, 0); }\n"
                  "    // Do not spend the bounded read attempts")
    if reader_pin not in payload:
        result.append("the peer reader no longer pins itself to the cpu its "
                      "progress handler names")
    if "return workload_busy_primary_candidate(pid);" not in process:
        result.append("core-0 scheduler no longer applies primary admission")
    if "if (cpu != SECONDARY_CORE_ID) { return false; }" not in process:
        result.append("scheduler admits the workload to an unintended peer")
    for operation in ("OPENAT_SYSCALL", "READ_SYSCALL", "CLOSE_SYSCALL"):
        if operation not in payload:
            result.append(f"peer payload no longer performs {operation}")
    for shape in (
        "const PEER_READ_CHUNK: usize = 1024;",
        "const PEER_READ_CHUNKS: usize = 96;",
        "while (peer_read_cpu(cpu_bytes as []u8) != peer_cpu) {}",
        "while (peer_read_cpu(cpu_bytes as []u8) != 0) {}",
    ):
        if shape not in payload:
            result.append(f"payload placement or bounded-read shape changed: {shape}")
    if "tag == workload_busy_pair.peer_exit_tag" not in evidence:
        result.append("post-reap routing no longer survives pid reuse")
    marker = expected.strip()
    if marker != (
        "workload: peer read 98304 pattern bytes; block device mutex "
        "contended on both cpus"
    ):
        result.append("expected verdict changed")
    if view_filter.strip() != "^workload: peer read 98304 pattern bytes":
        result.append("view no longer selects the verdict")
    final_marker = (
        "peer user console: record=17/17 "
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    )
    for runner in (
        "scripts/run_kernel_qemutest.sh",
        "scripts/run_kernel_hwtest_rpi5.sh",
    ):
        if f"--stop-marker '{final_marker}'" not in tree[runner]:
            result.append(f"{runner} can stop before the verdict")
    return result


def main() -> int:
    tree = sources()
    found = problems(tree)
    if found:
        for problem in found:
            print(f"ERROR peer-filesystem-control: {problem}")
        return 1

    controls = []
    mutations = {
        "exclusion": ("kernel/drivers/block/memory.tkb", "task_mutex_trylock", "removed_trylock"),
        "cpu0 wait": ("kernel/kernel/workload_evidence.tkb", "block_device_wait_count(0)", "removed_cpu0_wait"),
        "secondary id": ("kernel/kernel/workload_evidence.tkb", "block_read_call_count(SECONDARY_CORE_ID)", "block_read_call_count(1)"),
        "primary admission": ("kernel/kernel/process.tkb", "workload_busy_primary_candidate(pid)", "removed_primary_candidate(pid)"),
        "reader pin": ("kernel/arch/arm64/kernel/peer_read.tkb", "if (peer_pin(peer_cpu) == false) { svc5(EXIT_SYSCALL, 1, 0, 0, 0, 0); }\n    // Do not spend the bounded read attempts", "// Do not spend the bounded read attempts"),
        "single peer": ("kernel/kernel/process.tkb", "cpu != SECONDARY_CORE_ID", "cpu == SECONDARY_CORE_ID"),
        "qemu stop": ("scripts/run_kernel_qemutest.sh", "--stop-marker", "--old-stop-marker"),
    }
    for name, (path, old, new) in mutations.items():
        changed = dict(tree)
        changed[path] = changed[path].replace(old, new, 1)
        if not problems(changed):
            print(f"ERROR peer-filesystem-control: {name} negative control passed")
            return 1
        controls.append(name)

    report_pass("peer-filesystem-controls",
                f"{len(tree)} production files and {len(controls)} negative controls",
                files=len(tree))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
