#!/usr/bin/env python3
"""Check the host/guest persistent HTTPd handshake and blocking accept.

The HTTPd child publishes LISTENER before blocking in accept4().  The host
must start its request from that state, then independently require READY to
prove that the parent shell resumed, and only then publish DONE.  Waiting for
READY before sending the request creates a circular wait hidden by accept4's
deadline. The same deadline belongs only to an incomplete TCP handshake: a
blocking accept must wait again rather than expose EAGAIN to HTTPd. Keep these
cheap structural checks in langcheck so the production-shaped service cannot
silently regain either lifecycle defect.
"""

from pathlib import Path
import re
import sys

from pass_line import report_pass


ROOT = Path(__file__).resolve().parent.parent
RUNNERS = (
    "scripts/run_kernel_qemutest.sh",
    "scripts/run_kernel_alloc_rollback_qemutest.sh",
    "scripts/run_kernel_hwtest_rpi5.sh",
)


def position(text: str, pattern: str, runner: str) -> int | None:
    match = re.search(pattern, text, re.MULTILINE)
    if match is None:
        print(f"ERROR\t{runner}: missing init-managed HTTPd protocol step: {pattern}")
        return None
    return match.start()


def main() -> int:
    failed = False
    inittab = (ROOT / "kernel/tests/ext2/inittab").read_text(encoding="ascii")
    # The integration image pins the service to CPU 1 through util-linux
    # taskset (GitHub issues #581 and #591); the interactive image does not.
    if ("::respawn:/bin/taskset -c 1 /bin/httpd -f -p 8080 -h /\n"
            not in inittab):
        print("ERROR\tinittab does not respawn the persistent HTTPd service")
        failed = True
    shell_inittab = (ROOT / "kernel/tests/ext2/inittab.shell").read_text(
        encoding="ascii"
    )
    if "::sysinit:" in shell_inittab:
        print("ERROR\tinteractive inittab runs the finite integration sysinit")
        failed = True
    for service, description in (
        ("::respawn:/bin/httpd -f -p 8080 -h /\n", "persistent HTTPd"),
        ("::respawn:/bin/sh -i\n", "persistent ash"),
    ):
        if shell_inittab.count(service) != 1:
            print(f"ERROR\tinteractive inittab must respawn one {description}")
            failed = True
    console = (ROOT / "scripts/run_kernel_shell_console.py").read_text(
        encoding="ascii"
    )
    expected_listener = (
        'LISTENER_MARKERS = (b"persistent server: listener ready port=8080",)'
    )
    if expected_listener not in console:
        print("ERROR\tinteractive URL is not gated by exact listener readiness")
        failed = True
    for runner, expected in (
        ("scripts/run_kernel_shell_qemu.sh", 'ext2-shell.img"'),
        ("scripts/run_kernel_shell_rpi5.sh", 'kernel-shell.elf"'),
    ):
        runner_text = (ROOT / runner).read_text(encoding="ascii")
        if expected not in runner_text:
            print(f"ERROR\t{runner} does not select the interactive rootfs")
            failed = True
    syscall = (ROOT / "kernel/kernel/syscall.tkb").read_text(encoding="ascii")
    gave_up = re.search(
        r"KernelTcpAcceptStep::GaveUp\(next\) => \{(?P<body>.*?)"
        r"KernelTcpAcceptStep::Accepted",
        syscall,
        re.DOTALL,
    )
    if gave_up is None or "Resume(LINUX_EAGAIN)" in gave_up.group("body"):
        print("ERROR\tblocking accept exposes handshake expiry as EAGAIN")
        failed = True
    if "foreground_server_should_bound" in syscall:
        print("ERROR\taccept still contains request-count process termination")
        failed = True
    deadline = re.search(
        r"accept_deadline_ticks\s*=\s*counter_frequency\s*\*\s*(\d+)",
        (ROOT / "kernel/net/tcp.tkb").read_text(encoding="ascii"),
    )
    qemu_runner = (ROOT / "scripts/run_kernel_qemutest.sh").read_text(
        encoding="ascii")
    idle = re.search(r"KERNEL_HTTPD_IDLE_SECONDS=(\d+)", qemu_runner)
    peer = (ROOT / "scripts/kernel_net_test.py").read_text(encoding="ascii")
    if (deadline is None or idle is None or
            int(idle.group(1)) <= int(deadline.group(1)) or
            "time.sleep(HTTPD_IDLE_SECONDS)" not in peer):
        print("ERROR\tQEMU does not request HTTP after the accept deadline")
        failed = True
    uart_driver = (ROOT / "scripts/run_kernel_uart_driver.py").read_text(
        encoding="ascii")
    guard_arg = '--httpd-peer-guard-file "$HTTPD_GUARD_FILE"'
    if (qemu_runner.count(guard_arg) != 2 or
            'HTTPD_GUARD_FILE="$ARTIFACT_DIR/httpd-peer-guard.until"' not in qemu_runner or
            '"$HTTPD_GUARD_FILE"' not in qemu_runner.split("rm -f", 1)[1] or
            "guard_httpd_peer(HTTPD_IDLE_SECONDS + 2.0)" not in peer or
            peer.count("guard_httpd_peer(12.0)") != 2 or
            "now >= peer_guard_until" not in uart_driver):
        print("ERROR\tQEMU HTTPd peer deadlines are not shared with the UART watchdog")
        failed = True
    for runner in RUNNERS:
        text = (ROOT / runner).read_text(encoding="utf-8")
        listener_arg = position(
            text,
            r'--interactive-httpd-listener-file "\$INTERACTIVE_HTTPD_LISTENER"',
            runner,
        )
        ready_arg = position(
            text,
            r'--interactive-httpd-ready-file "\$INTERACTIVE_HTTPD_READY"',
            runner,
        )
        done_arg = position(
            text,
            r'--interactive-httpd-done-file "\$INTERACTIVE_HTTPD_DONE"',
            runner,
        )
        if runner.endswith("run_kernel_hwtest_rpi5.sh"):
            listener_check = position(
                text, r'-f "\$INTERACTIVE_HTTPD_LISTENER"', runner
            )
            request = position(text, r'http://\$\{ETH_TEST_SUBNET\}', runner)
            ready_check = position(text, r'-f "\$INTERACTIVE_HTTPD_READY"', runner)
            ordered = lambda: listener_check <= request < ready_check < done
        else:
            # kernel_net_test waits for this file before its first request.
            listener_check = request = position(
                text,
                r'--interactive-ready-file "\$INTERACTIVE_HTTPD_LISTENER"',
                runner,
            )
            # The UART driver does not finish until READY and DONE both exist.
            ready_check = ready_arg
            ordered = lambda: request < done
        done = position(text, r'^touch "\$INTERACTIVE_HTTPD_DONE"$', runner)
        positions = (
            listener_arg, ready_arg, done_arg, listener_check, request,
            done, ready_check,
        )
        if any(item is None for item in positions):
            failed = True
            continue
        assert listener_check is not None and request is not None
        assert ready_check is not None and done is not None
        if not ordered():
            print(
                f"ERROR\t{runner}: expected request-from-LISTENER, then READY "
                "validation, then DONE publication"
            )
            failed = True
    if failed:
        print("FAIL kernel-interactive-httpd-protocol")
        return 1
    report_pass(
        "kernel-interactive-httpd-protocol",
        f"persistent services plus {len(RUNNERS)} runners preserve blocking accept and LISTENER -> request -> READY -> DONE",
        runners=len(RUNNERS),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
