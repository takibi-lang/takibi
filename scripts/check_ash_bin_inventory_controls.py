#!/usr/bin/env python3
"""Positive and failure-specific controls for the ash /bin inventory check."""

from pathlib import Path

import check_ash_bin_inventory as check
from pass_line import report_pass


ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    controls = []
    makefile = (ROOT / "Makefile").read_text(encoding="ascii")
    stdin = (ROOT / "kernel/tests/common/ash/ash.stdin").read_text(
        encoding="ascii")
    expected = (ROOT / "kernel/tests/common/ash/ash.expected").read_text(
        encoding="ascii")
    workload = (ROOT / "kernel/kernel/workload_evidence.tkb").read_text(
        encoding="ascii")
    syscall = (ROOT / "kernel/kernel/syscall.tkb").read_text(
        encoding="ascii")
    names = check.image_bin_names(makefile)
    assert names == check.expected_bin_names(stdin, expected)
    assert check.busybox_sleep_probe_is_real(makefile, stdin, workload,
                                             syscall)
    controls.append("current tree")
    injected = makefile.replace(
        "$(KERNEL_SHELL_EXT2_IMAGE):",
        "\tE2FSPROGS_FAKE_TIME=1700000000 e2cp fixture "
        "$@.tmp:/bin/new-fixture\n\n$(KERNEL_SHELL_EXT2_IMAGE):", 1)
    assert "new-fixture" in check.image_bin_names(injected)
    assert check.image_bin_names(injected) != check.expected_bin_names(
        stdin, expected)
    controls.append("added image entry")
    removed = expected.replace("peer-spin\n", "", 1)
    assert names != check.expected_bin_names(stdin, removed)
    controls.append("missing expected entry")
    try:
        check.image_bin_names(makefile.replace(
            "$@.tmp:/bin/peer-spin", "$@.tmp:/bin/peer-spin.extra-syntax", 1))
    except ValueError:
        # A valid new name is not an unsupported command, so test a malformed
        # path spelling instead below.
        raise AssertionError("valid image name was refused")
    malformed = makefile.replace("$@.tmp:/bin/peer-spin",
                                 "$@.tmp:/bin/peer-spin/child", 1)
    try:
        check.image_bin_names(malformed)
    except ValueError:
        pass
    else:
        raise AssertionError("unrecognized /bin recipe syntax was accepted")
    controls.append("unrecognized recipe")
    wrong_applet = makefile.replace(
        "link /bin/busybox.static /bin/sleep",
        "link /bin/busybox-extras /bin/sleep", 1)
    assert not check.busybox_sleep_probe_is_real(
        wrong_applet, stdin, workload, syscall)
    no_applet = stdin.replace("/bin/sleep 1 >/dev/null", "/bin/spin", 1)
    assert not check.busybox_sleep_probe_is_real(
        makefile, no_applet, workload, syscall)
    no_guard_reap = stdin.replace('wait "$placement_guard_pid"\n', "", 1)
    assert not check.busybox_sleep_probe_is_real(
        makefile, no_guard_reap, workload, syscall)
    no_identity = workload.replace('bs"/bin/sleep\\0"',
                                   'bs"/bin/spin\\0"', 1)
    assert not check.busybox_sleep_probe_is_real(
        makefile, stdin, no_identity, syscall)
    truncated_identity = workload.replace(
        "command_line[0..<11]", "command_line[0..<9]", 1)
    assert not check.busybox_sleep_probe_is_real(
        makefile, stdin, truncated_identity, syscall)
    controls.append("BusyBox target and same-process placement evidence")
    report_pass("ash-bin-inventory controls",
                "current inventory passes; additions, omissions, and "
                "unrecognized image commands, a non-BusyBox sleep target, "
                "a wait-PID fixture, a truncated sleep identity, and lost "
                "same-process placement evidence are refused",
                controls=len(controls))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
