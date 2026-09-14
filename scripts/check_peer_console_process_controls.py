#!/usr/bin/env python3
"""Keep the peer-console view tied to a real admitted EL0 short write."""

from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent


def sources() -> dict[str, str]:
    names = [
        "Makefile",
        "kernel/arch/arm64/kernel/peer_read.tkb",
        "kernel/kernel/process.tkb",
        "kernel/kernel/syscall.tkb",
        "kernel/kernel/workload_evidence.tkb",
        "kernel/tests/ext2/inittab",
        "kernel/tests/common/views/peer_console_process.expected",
        "kernel/tests/common/views/peer_console_process.filter",
        "scripts/run_kernel_qemutest.sh",
        "scripts/run_kernel_hwtest_rpi5.sh",
    ]
    return {name: (ROOT / name).read_text() for name in names}


def problems(tree: dict[str, str]) -> list[str]:
    payload = tree["kernel/arch/arm64/kernel/peer_read.tkb"]
    evidence = tree["kernel/kernel/workload_evidence.tkb"]
    process = tree["kernel/kernel/process.tkb"]
    expected = tree["kernel/tests/common/views/peer_console_process.expected"]
    result = []
    for shape in (
        "const WRITE_SYSCALL: usize = 64;",
        "output.len - total",
        "while (peer_read_cpu(cpu_bytes as []u8) != peer_cpu) {}",
    ):
        if shape not in payload:
            result.append(f"peer payload lost operation: {shape}")
    for condition in (
        "first != 1024",
        "total != 1088",
        "first != 1024 || total != 1088 ||\n"
        "        cpu_id() != SECONDARY_CORE_ID",
    ):
        if condition not in evidence:
            result.append(f"verdict no longer rejects missing {condition}")
    if "pid == workload_busy_pair.peer_console_pid" not in evidence:
        result.append("secondary admission no longer selects the writer")
    primary_shape = (
        "return workload_busy_pair.peer_console_pid == 0 ||\n"
        "           workload_busy_pair.peer_console_reported ||\n"
        "           pid != workload_busy_pair.peer_console_pid;"
    )
    if primary_shape not in evidence:
        result.append("primary admission no longer excludes the writer")
    if "if (cpu != SECONDARY_CORE_ID) { return false; }" not in process:
        result.append("scheduler admits the writer to an unintended peer")
    if "if (x0 == 4)" not in tree["kernel/kernel/syscall.tkb"]:
        result.append("workload syscall no longer routes the writer tag")
    if "::once:/bin/peer-console" not in tree["kernel/tests/ext2/inittab"]:
        result.append("init no longer starts the real writer")
    if "$(KERNEL_PEER_CONSOLE_ELF)" not in tree["Makefile"]:
        result.append("rootfs no longer depends on the writer ELF")
    lines = expected.splitlines()
    if len(lines) != 18 or "record=01/17" not in lines[0] or \
            "record=17/17" not in lines[-1]:
        result.append("view no longer fixes all seventeen bounded records")
    if tree["kernel/tests/common/views/peer_console_process.filter"].strip() != \
            "^peer user console:|^workload: peer console short-wrote":
        result.append("view no longer selects records and short-write verdict")
    stop = "--stop-marker 'peer user console: record=17/17 " \
           "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'"
    for runner in ("scripts/run_kernel_qemutest.sh",
                   "scripts/run_kernel_hwtest_rpi5.sh"):
        if stop not in tree[runner]:
            result.append(f"{runner} can stop before the final record")
    return result


def main() -> int:
    tree = sources()
    found = problems(tree)
    if found:
        for problem in found:
            print(f"ERROR peer-console-process-control: {problem}")
        return 1

    mutations = {
        "write syscall": ("kernel/arch/arm64/kernel/peer_read.tkb",
                          "const WRITE_SYSCALL", "const OLD_WRITE_SYSCALL"),
        "short count": ("kernel/kernel/workload_evidence.tkb",
                        "first != 1024", "first != 1088"),
        "placement": ("kernel/kernel/workload_evidence.tkb",
                      "first != 1024 || total != 1088 ||\n"
                      "        cpu_id() != SECONDARY_CORE_ID",
                      "first != 1024 || total != 1088 ||\n"
                      "        cpu_id() == SECONDARY_CORE_ID"),
        "primary exclusion": ("kernel/kernel/workload_evidence.tkb",
                              "           pid != workload_busy_pair.peer_console_pid;",
                              "           pid == workload_busy_pair.peer_console_pid;"),
        "init entry": ("kernel/tests/ext2/inittab", "::once:/bin/peer-console",
                       "::once:/bin/old-console"),
        "qemu stop": ("scripts/run_kernel_qemutest.sh", "--stop-marker",
                      "--old-stop-marker"),
    }
    for name, (path, old, new) in mutations.items():
        changed = dict(tree)
        changed[path] = changed[path].replace(old, new, 1)
        if not problems(changed):
            print(f"ERROR peer-console-process-control: {name} negative control passed")
            return 1

    report_pass("peer-console-process-controls",
                f"{len(tree)} production files and {len(mutations)} negative controls",
                files=len(tree))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
