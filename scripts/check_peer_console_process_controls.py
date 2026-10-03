#!/usr/bin/env python3
"""Keep the peer-console view tied to real admitted EL0 shared-queue writes."""

from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent


def sources() -> dict[str, str]:
    names = [
        "Makefile",
        "kernel/printk/log.tkb",
        "kernel/tests/common/views/console_order.expected",
        "kernel/tests/common/views/console_order.filter",
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
        "first != workload_busy_pair.peer_console_first_count || total != 1071",
        "first == 0 || first > 1071 || total != 0",
        "total != 1071",
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
    if "        peer_console_ddb_hold(SECONDARY_CORE_ID);\n" \
       "        process_run_unlock(guard);\n" \
       "        return SECONDARY_CORE_ID;" not in evidence:
        result.append("registration no longer hands the writer its peer CPU")
    # Holding the old ring makes regression to separate peer admission
    # reorder the migration fixture rather than pass by drain timing.
    if "        workload_busy_pair.peer_console_pid = pid;\n" \
       "        // The legacy ring stays held through the ordering fixture" not in evidence:
        result.append("registration no longer holds core 0's drain of the "
                      "writer's ring for its first write")
    if "svc5(WORKLOAD_PROGRESS_SYSCALL, PEER_CONSOLE_TAG, first, 0, 0, 0) == 0" \
            not in tree["kernel/arch/arm64/kernel/peer_read.tkb"]:
        result.append("the writer no longer reports its first write before "
                      "it retries")
    if "peer_console_first_seen == false) {\n" \
       "            peer_console_ddb_clear(SECONDARY_CORE_ID);" not in evidence:
        result.append("the writer's first report no longer releases the "
                      "drain it was held under")
    if "if (workload_busy_pair.peer_read_reported == false) {" not in evidence:
        result.append("writer is named a CPU before the reader's verdict")
    if "return svc5(SETAFFINITY_SYSCALL, 0, 8, mask as *u8 as usize, 0, 0) == 0;" \
            not in payload:
        result.append("writer no longer pins itself to the CPU it was given")
    # Every self-placing fixture in this payload must exit when its own pin
    # fails, so this counts the sites rather than merely finding one:
    # presence alone could never notice one of several going.
    #
    # Three since GitHub issue #581: the console writer, the terminal reader,
    # and the filesystem reader. Each asks for its CPU through the progress
    # handler and pins itself; none needs a named-pid placement exception.
    if payload.count(
            "if (peer_pin(peer_cpu) == false) { "
            "svc5(EXIT_SYSCALL, 1, 0, 0, 0, 0); }") != 3:
        result.append("a self-placing fixture proceeds when its pin failed")
    if ("return (mask & kernel_process_online_mask() & (1 << bit)) != 0;"
            not in process):
        result.append("scheduler no longer honors the writer's explicit peer mask")
    if "if (x0 == 4)" not in tree["kernel/kernel/syscall.tkb"]:
        result.append("workload syscall no longer routes the writer tag")
    if "::once:/bin/peer-console" not in tree["kernel/tests/ext2/inittab"]:
        result.append("init no longer starts the real writer")
    for command in ("/bin/busy-a", "/bin/busy-b",
                    "/bin/taskset -c 1 /bin/httpd -f -p 8080 -h /"):
        if "null::respawn:" + command not in tree["kernel/tests/ext2/inittab"]:
            result.append("a background respawn can reset the interactive UART")
    if "$(KERNEL_PEER_CONSOLE_ELF)" not in tree["Makefile"]:
        result.append("rootfs no longer depends on the writer ELF")
    # The records and the verdict are two views. The verdict is a peer kernel
    # log line, which reaches the wire through a different channel, so where
    # it falls among the records is drain timing: after record 16 on QEMU,
    # after record 8 on RPi5, whose 512-byte transmit queue holds eight.
    lines = expected.splitlines()
    if len(lines) != 17 or "record=01/17" not in lines[0] or \
            "record=17/17" not in lines[-1] or any(len(line) != 62 for line in lines):
        result.append("view no longer fixes all seventeen bounded records")
    if tree["kernel/tests/common/views/peer_console_process.filter"].strip() != \
            "^peer user console: record=":
        result.append("view no longer selects exactly the numbered records")
    if tree["kernel/tests/common/views/peer_console_verdict.filter"].strip() != \
            "^workload: peer console accepted all" or \
            "all 1071 bytes through the shared queue" not in \
            tree["kernel/tests/common/views/peer_console_verdict.expected"]:
        result.append("verdict view no longer fixes the shared-queue verdict")
    stop = "--stop-marker 'peer user console: record=17/17 " \
           "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'"
    for runner in ("scripts/run_kernel_qemutest.sh",
                   "scripts/run_kernel_hwtest_rpi5.sh"):
        if stop not in tree[runner]:
            result.append(f"{runner} can stop before the final record")
    log = tree["kernel/printk/log.tkb"]
    writer = log.split("private fn uart_user_write_locked(", 1)[1].split("// Queue what fits", 1)[0]
    if "peer_console_publish" in writer or "cpu != 0" in writer:
        result.append("ordinary peer writes still use the separate record ring")
    if "workload_busy_pair.peer_console_order_step != 6" not in evidence:
        result.append("verdict does not require every ordering step")
    if "total != workload_busy_pair.peer_console_order_step + 1" not in evidence:
        result.append("ordering reports can skip a step")
    if "parent == workload_busy_pair.peer_console_pid" not in evidence:
        result.append("second writer is not tied to the first writer's child")
    order = tree["kernel/tests/common/views/console_order.expected"].splitlines()
    if order != ["console order: 1 migrating peer", "console order: 2 migrating core0",
                 "console order: 3 migrating peer", "console order: 4 parent peer",
                 "console order: 5 child core0", "console order: 6 parent peer"]:
        result.append("view does not fix migrating and two-process write order")
    if tree["kernel/tests/common/views/console_order.filter"].strip() != "^console order:":
        result.append("ordering view lost its exact selection")
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
                        "first != workload_busy_pair.peer_console_first_count || total != 1071",
                        "first != 1071 || total != 1071"),
        "first count report": ("kernel/kernel/workload_evidence.tkb",
                               "first == 0 || first > 1071 || total != 0",
                               "first != 1071 || total != 0"),
        "drain held for the first write": (
            "kernel/kernel/workload_evidence.tkb",
            "        peer_console_ddb_hold(SECONDARY_CORE_ID);\n"
            "        process_run_unlock(guard);\n"
            "        return SECONDARY_CORE_ID;",
            "        process_run_unlock(guard);\n"
            "        return SECONDARY_CORE_ID;"),
        "drain released after the first write": (
            "kernel/kernel/workload_evidence.tkb",
            "peer_console_first_seen == false) {\n"
            "            peer_console_ddb_clear(SECONDARY_CORE_ID);",
            "peer_console_first_seen == false) {"),
        "writer reports its first write": (
            "kernel/arch/arm64/kernel/peer_read.tkb",
            "svc5(WORKLOAD_PROGRESS_SYSCALL, PEER_CONSOLE_TAG, first, 0, 0, 0) == 0",
            "svc5(WORKLOAD_PROGRESS_SYSCALL, PEER_CONSOLE_TAG, first, 0, 0, 0) == 99"),
        "placement": ("kernel/kernel/workload_evidence.tkb",
                      "        workload_busy_pair.peer_console_reported ||\n"
                      "        cpu_id() != SECONDARY_CORE_ID",
                      "        workload_busy_pair.peer_console_reported ||\n"
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
            "        peer_console_ddb_hold(SECONDARY_CORE_ID);\n"
            "        process_run_unlock(guard);\n"
            "        return SECONDARY_CORE_ID;",
            "        peer_console_ddb_hold(SECONDARY_CORE_ID);\n"
            "        process_run_unlock(guard);\n"
            "        return 0;"),
        "turn before the reader": ("kernel/kernel/workload_evidence.tkb",
                                   "if (workload_busy_pair.peer_read_reported == false) {",
                                   "if (workload_busy_pair.peer_read_reported) {"),
        "self pin": ("kernel/arch/arm64/kernel/peer_read.tkb",
                     "return svc5(SETAFFINITY_SYSCALL, 0, 8, mask as *u8 as usize, 0, 0) == 0;",
                     "return true;"),
        "explicit cpu mask": (
            "kernel/kernel/process.tkb",
            "return (mask & kernel_process_online_mask() & (1 << bit)) != 0;",
            "return cpu == SECONDARY_CORE_ID;"),
        # Either site losing its exit must be caught, and the assertion above
        # counts both, so mutating the first copy is enough here.
        "pin failure ignored": (
            "kernel/arch/arm64/kernel/peer_read.tkb",
            "if (peer_pin(peer_cpu) == false) { svc5(EXIT_SYSCALL, 1, 0, 0, 0, 0); }",
            "if (peer_pin(peer_cpu) == false) { }"),
        "init entry": ("kernel/tests/ext2/inittab", "::once:/bin/peer-console",
                       "::once:/bin/old-console"),
        "background tty": ("kernel/tests/ext2/inittab",
                           "null::respawn:/bin/busy-a", "::respawn:/bin/busy-a"),
        "converted record width": ("kernel/tests/common/views/peer_console_process.expected",
                                   "record=08/17 ", "record=008/17 "),
        "qemu stop": ("scripts/run_kernel_qemutest.sh", "--stop-marker",
                      "--old-stop-marker"),
    }
    mutations.update({
        "all ordering steps": ("kernel/kernel/workload_evidence.tkb",
                               "workload_busy_pair.peer_console_order_step != 6",
                               "workload_busy_pair.peer_console_order_step != 0"),
        "ordered reports": ("kernel/kernel/workload_evidence.tkb",
                            "total != workload_busy_pair.peer_console_order_step + 1",
                            "total != workload_busy_pair.peer_console_order_step"),
        "child identity": ("kernel/kernel/workload_evidence.tkb",
                           "parent == workload_busy_pair.peer_console_pid",
                           "parent != workload_busy_pair.peer_console_pid"),
        "shared peer admission": ("kernel/printk/log.tkb",
                                  "    let mut taken: usize = 0;",
                                  "    if (cpu_id() != 0) { return (peer_console_publish(cpu_id(), bytes), false); }\n    let mut taken: usize = 0;"),
        "wire order": ("kernel/tests/common/views/console_order.expected",
                       "console order: 1 migrating peer", "console order: 1 core0"),
    })
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
