"""Hold a Debug Probe UART in BREAK until the answer has come back (#1300).

Ending a BREAK can corrupt what the board is printing at that moment. The
probe's firmware ends it with the Pico SDK's uart_set_break, which disables
the PL011 receiver for about 15 bit times around the register write. A
character being received when the disable lands still completes, but the
receiver then returns inside a later character and frames from a data bit.
Later bytes stay misframed until an idle gap, so `ddb> ` read back as
`d\\x89\\xf9\\x81\\xff`. The line carried the right bytes all along.

pyserial's send_break(0.25) does not hold for 0.25 s either: it calls
tcsendbreak(fd, int(duration / 0.25)), which Linux treats as 100 ms. A
hung-core DDB entry prompts about 100 ms after the BREAK, because the world
stop escalates to the pseudo-NMI first, so that release could land on the
prompt. Measured on RPi5: 15 of 35 sessions lost the prompt with send_break,
0 of 35 with a 250 ms hold.

So hold the line past the slowest answer measured and release into silence.
scripts/check_uart_break_path.py refuses a direct send_break.
"""

import time

# Ten times the slowest prompt measured (about 105 ms, hung core). DDB waits
# for input at its prompt, so the longer hold costs only this time.
BREAK_HOLD_SECONDS = 1.0


def hold_break(uart, sleep=time.sleep):
    """Assert BREAK, wait out the board's answer, and release it."""
    uart.break_condition = True
    sleep(BREAK_HOLD_SECONDS)
    uart.break_condition = False
