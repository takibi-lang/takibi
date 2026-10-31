#!/usr/bin/env python3
"""Controls for check_uart_break_path.py and uart_break.hold_break (#1300)."""

import sys

from check_uart_break_path import problems
from pass_line import report_pass
from uart_break import BREAK_HOLD_SECONDS, hold_break

# The slowest DDB prompt measured after a BREAK starts: hung core, RPi5.
SLOWEST_PROMPT_SECONDS = 0.105


class Port:
    """Records the line state whenever the hold sleeps or changes it."""

    def __init__(self):
        self.states = []

    @property
    def break_condition(self):
        return self.states[-1]

    @break_condition.setter
    def break_condition(self, value):
        self.states.append(value)


def main():
    cases = (("uart.send_break(0.25)\n", True),
             ("termios.tcsendbreak(fd, 1)\n", True),
             ("x = lambda: uart.send_break(0.25)\n", True),
             ("class Fake:\n    def send_break(self, d):\n        pass\n", False),
             ("board.send_break = refuse\nsend_break()\n", False))
    for source, refused in cases:
        if bool(problems(source)) != refused:
            print(f"FAIL uart-break-path control: {source!r}", file=sys.stderr)
            return 1
    port = Port()
    slept = []
    hold_break(port, sleep=lambda seconds: slept.append((seconds, port.break_condition)))
    if port.states != [True, False] or slept != [(BREAK_HOLD_SECONDS, True)]:
        print(f"FAIL hold_break: {port.states} {slept}", file=sys.stderr)
        return 1
    if BREAK_HOLD_SECONDS <= SLOWEST_PROMPT_SECONDS:
        print("FAIL hold_break releases before the slowest prompt", file=sys.stderr)
        return 1
    report_pass("uart-break-path controls", "refused and allowed calls, and one hold",
                sources=len(cases))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
