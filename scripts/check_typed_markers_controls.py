#!/usr/bin/env python3
"""Controls for check_typed_markers.py: each refused shape is refused, each
allowed shape is allowed, and the #857 drivers' old spellings are refused."""

import check_typed_markers as check
from pass_line import CaseCount, report_pass

CASES = CaseCount()


def refused(source, needle):
    CASES.note()
    found, typed = check.problems_in(source, "control.py")
    assert typed, ("nothing typed was seen", source)
    assert found and needle in found[0], (source, found)


def allowed(source):
    CASES.note()
    found, typed = check.problems_in(source, "control.py")
    assert typed, ("nothing typed was seen", source)
    assert not found, (source, found)


def main():
    # The #856 and #857 shapes, as the drivers spelled them before the fix.
    refused('import os\nM = b"__X__"\nos.write(t, b"ps; echo " + M + b"\\n")\n',
            "echo __X__")
    refused('session.send(b"echo __BULK_TCP_DONE__\\n")\n', "__BULK_TCP_DONE__")
    refused('uart.write(b"echo ddb-resume-ok\\n")\n', "ddb-resume-ok")
    refused('write_line(uart, b"echo ddb-software-resume-ok")\n',
            "ddb-software-resume-ok")
    refused('DONE = b"__D__"\ns.send(c.encode() + b"; echo " + DONE + b"\\n")\n',
            "__D__")
    refused('C = b"echo uart-wake-ok\\n"\nfor i, v in enumerate(C):\n'
            '    conn.sendall(bytes([v]))\n', "uart-wake-ok")
    # A word the fold cannot see is refused: a reviewer cannot see it either.
    refused('def f(m):\n    s.send(b"echo " + m + b"\\n")\n', "<unseen>")
    # A name bound to two values is not trusted to be either.
    refused('m = b"__A\'\'B__"\nm = 3\ns.send(b"echo " + m + b"\\n")\n',
            "<unseen>")
    # Allowed shapes.
    allowed('from typed_marker import typed_marker\nM = b"__X__"\n'
            'os.write(t, b"echo " + typed_marker(M) + b"; ps\\n")\n')
    allowed('ANSWER = "ok-ok"\nC = b"echo " + typed_marker(ANSWER.encode()) + b"\\n"\n'
            'for i, v in enumerate(C):\n    conn.sendall(bytes([v]))\n')
    allowed('s.send(b"echo stop > /proc/takibi/profile\\n")\n')
    allowed('s.send(b"x=; echo\\n")\n')
    allowed('s.send(b"/bin/peer-tty\\n")\n')
    # A str write is a file or log write, not a console line.
    CASES.note()
    found, typed = check.problems_in('f.write("echo hello\\n")\n', "c.py")
    assert not found and typed == 0, (found, typed)
    # The drivers #857 fixed pass as they stand (the whole tree is the
    # check's own run in the same lane).
    for name in ("run_kernel_shell_qemu_smoketest.py", "kernel_uart_wake_check.py",
                 "run_kernel_ddb_rpi5_driver.py", "profile_kernel_session.py"):
        CASES.note()
        found, typed = check.problems_in(
            (check.ROOT / "scripts" / name).read_text(encoding="ascii"), name)
        assert typed and not found, (name, found)
    report_pass("typed-markers-controls",
                f"{CASES.ran} cases; unquoted typed markers refused",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
