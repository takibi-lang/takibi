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
        "kernel/tests/common/views/peer_console_verdict.expected",
        "kernel/tests/common/views/peer_console_verdict.filter",
        "scripts/run_kernel_qemutest.sh",
        "scripts/run_kernel_hwtest_rpi5.sh",
        "scripts/run_kernel_ddb_qemutest.sh",
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
        "workload_busy_pair.peer_console_reported ||\n"
        "        cpu_id() != SECONDARY_CORE_ID",
    ):
        if condition not in evidence:
            result.append(f"verdict no longer rejects missing {condition}")
    # The DDB lanes keep the writer past its view; every other boot must
    # release it at its first verdict, or it spins on the peer forever.
    if "if (kernel_ddb_peer_console_test_enabled == false) {" not in evidence:
        result.append("writer outlives its view on boots without a DDB lane")
    if "kernel_ddb_peer_console_test_enabled = 1" not in \
            tree["scripts/run_kernel_ddb_qemutest.sh"]:
        result.append("QEMU DDB lane no longer holds a peer record")
    if "RPI5_ARM_PEER_CONSOLE_DDB=1" not in \
            tree["scripts/run_kernel_hwtest_rpi5.sh"]:
        result.append("RPi5 DDB half no longer holds a peer record")
    # GitHub issue #9: the writer's placement is no longer an admission rule
    # naming its pid. It asks its progress handler for a CPU and pins itself
    # there with sched_setaffinity, so the property to guard is that handout
    # and that pin -- the two halves that put this writer on the peer.
    #
    # The handout also carries the writer's TURN, which the rule used to
    # carry: the CPU is named only once the filesystem reader has reported,
    # and asking earlier is not counted as a refusal.
    if "        workload_busy_pair.peer_console_pid = pid;\n" \
       "        process_run_unlock(guard);\n" \
       "        return SECONDARY_CORE_ID;" not in evidence:
        result.append("registration no longer hands the writer its peer CPU")
    if "if (workload_busy_pair.peer_read_reported == false) {" not in evidence:
        result.append("writer is named a CPU before the reader's verdict")
    if "return svc5(SETAFFINITY_SYSCALL, 0, 8, mask as *u8 as usize, 0, 0) == 0;" \
            not in payload:
        result.append("writer no longer pins itself to the CPU it was given")
    # Both self-placing fixtures in this payload -- the console writer and
    # the terminal reader -- must exit when their own pin fails, so this
    # counts the sites rather than merely finding one: with two copies in the
    # file, presence alone could never notice one of them going.
    if payload.count(
            "if (peer_pin(peer_cpu) == false) { "
            "svc5(EXIT_SYSCALL, 1, 0, 0, 0, 0); }") != 2:
        result.append("a self-placing fixture proceeds when its pin failed")
    if "if (cpu != SECONDARY_CORE_ID) { return false; }" not in process:
        result.append("scheduler admits the writer to an unintended peer")
    if "if (x0 == 4)" not in tree["kernel/kernel/syscall.tkb"]:
        result.append("workload syscall no longer routes the writer tag")
    if "::once:/bin/peer-console" not in tree["kernel/tests/ext2/inittab"]:
        result.append("init no longer starts the real writer")
    if "$(KERNEL_PEER_CONSOLE_ELF)" not in tree["Makefile"]:
        result.append("rootfs no longer depends on the writer ELF")
    # The records and the verdict are two views. The verdict is a peer kernel
    # log line, which reaches the wire through a different channel, so where
    # it falls among the records is drain timing: after record 16 on QEMU,
    # after record 8 on RPi5, whose 512-byte transmit queue holds eight.
    lines = expected.splitlines()
    if len(lines) != 17 or "record=01/17" not in lines[0] or \
            "record=17/17" not in lines[-1]:
        result.append("view no longer fixes all seventeen bounded records")
    if tree["kernel/tests/common/views/peer_console_process.filter"].strip() != \
            "^peer user console: record=":
        result.append("view no longer selects exactly the numbered records")
    if tree["kernel/tests/common/views/peer_console_verdict.filter"].strip() != \
            "^workload: peer console short-wrote" or \
            "1024 of 1088 bytes" not in \
            tree["kernel/tests/common/views/peer_console_verdict.expected"]:
        result.append("verdict view no longer fixes the short-write verdict")
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
                      "        cpu_id() != SECONDARY_CORE_ID",
                      "        cpu_id() == SECONDARY_CORE_ID"),
        "ddb gate": ("kernel/kernel/workload_evidence.tkb",
                     "kernel_ddb_peer_console_test_enabled == false",
                     "kernel_ddb_peer_console_test_enabled == true"),
        "qemu ddb hold": ("scripts/run_kernel_ddb_qemutest.sh",
                          "kernel_ddb_peer_console_test_enabled = 1",
                          "kernel_ddb_peer_console_test_enabled = 0"),
        "rpi5 ddb hold": ("scripts/run_kernel_hwtest_rpi5.sh",
                          "RPI5_ARM_PEER_CONSOLE_DDB=1",
                          "RPI5_ARM_PEER_CONSOLE_DDB=0"),
        # Three handlers return SECONDARY_CORE_ID; this one is the writer's,
        # so the mutation carries the registration line above it or it would
        # rewrite a sibling fixture's handout and prove nothing.
        "peer cpu handout": (
            "kernel/kernel/workload_evidence.tkb",
            "        workload_busy_pair.peer_console_pid = pid;\n"
            "        process_run_unlock(guard);\n"
            "        return SECONDARY_CORE_ID;",
            "        workload_busy_pair.peer_console_pid = pid;\n"
            "        process_run_unlock(guard);\n"
            "        return 0;"),
        "turn before the reader": ("kernel/kernel/workload_evidence.tkb",
                                   "if (workload_busy_pair.peer_read_reported == false) {",
                                   "if (workload_busy_pair.peer_read_reported) {"),
        "self pin": ("kernel/arch/arm64/kernel/peer_read.tkb",
                     "return svc5(SETAFFINITY_SYSCALL, 0, 8, mask as *u8 as usize, 0, 0) == 0;",
                     "return true;"),
        # Either site losing its exit must be caught, and the assertion above
        # counts both, so mutating the first copy is enough here.
        "pin failure ignored": (
            "kernel/arch/arm64/kernel/peer_read.tkb",
            "if (peer_pin(peer_cpu) == false) { svc5(EXIT_SYSCALL, 1, 0, 0, 0, 0); }\n"
            "    while (peer_read_cpu(cpu_bytes as []u8) != peer_cpu) {}\n"
            "\n"
            "    let first: usize = svc5(WRITE_SYSCALL, 1,",
            "if (peer_pin(peer_cpu) == false) { }\n"
            "    while (peer_read_cpu(cpu_bytes as []u8) != peer_cpu) {}\n"
            "\n"
            "    let first: usize = svc5(WRITE_SYSCALL, 1,"),
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
