#!/usr/bin/env python3
"""Postmortem for an RPi5 runner that reads the UART itself (GitHub issue #872).

scripts/run_kernel_hwtest_rpi5.sh hands its postmortem to
scripts/run_kernel_uart_driver.py through a request file (#869). The GEM
fixture runner and the shell smoke own their UART endpoint directly -- a
pyserial port, or the PTY around miniterm -- so they call this instead, with
three callables for that endpoint. The order and the questions are #869's:
an SWD snapshot of every core first (DDB stops every core, so a snapshot
after the BREAK would show the debugger, not the failure), then one BREAK,
then the driver's own POSTMORTEM_COMMANDS walk, bounded.

Nothing here raises: it runs inside a runner that has already failed, and a
diagnostic must not replace that runner's verdict.
"""

from pathlib import Path
import time

import rpi5_swd_snapshot
from run_kernel_uart_driver import DDB_PROMPT, POSTMORTEM_CEILING, POSTMORTEM_COMMANDS

# The kernel UART ISR drains one byte per interrupt; pace like the driver's
# write_uart_line so a command cannot outrun the 16-byte FIFO.
BYTE_PACE = 0.01


def collect(elf, directory, reason, *, send_break, write, read,
            budget=POSTMORTEM_CEILING, clock=time):
    """SWD snapshot, BREAK, DDB walk; return one line naming what was kept.

    send_break() delivers one BREAK, write(bytes) sends, read() returns what
    arrived (possibly b"") after a short wait. The walk is saved to
    ddb-postmortem.log and the snapshot to swd-snapshot.log in directory.
    """
    directory = Path(directory)
    swd_log = directory / "swd-snapshot.log"
    walk_log = directory / "ddb-postmortem.log"
    try:
        rpi5_swd_snapshot.capture(elf, swd_log, "before-break")
    except Exception as error:  # capture() already reports into its log.
        print(f"[kernel/rpi5] SWD snapshot unavailable: {error}", flush=True)
    walk = bytearray()
    sent = 0
    deadline = clock.monotonic() + budget
    try:
        send_break()
        while clock.monotonic() < deadline:
            walk.extend(read())
            prompts = walk.count(DDB_PROMPT)
            if prompts > len(POSTMORTEM_COMMANDS):
                break
            while sent < min(prompts, len(POSTMORTEM_COMMANDS)):
                for byte in POSTMORTEM_COMMANDS[sent] + b"\n":
                    write(bytes((byte,)))
                    clock.sleep(BYTE_PACE)
                sent += 1
        failure = ""
    except Exception as error:
        failure = f"; the walk stopped: {error}"
    answered = min(sent, max(0, walk.count(DDB_PROMPT) - 1))
    try:
        directory.mkdir(parents=True, exist_ok=True)
        walk_log.write_bytes(b"postmortem reason=" + reason.encode("ascii", "replace")
                             + b"\n" + bytes(walk))
    except OSError as error:
        failure += f"; could not save the walk: {error}"
    if not walk.count(DDB_PROMPT):
        state = "no DDB prompt after the BREAK"
    else:
        state = f"DDB answered {answered}/{len(POSTMORTEM_COMMANDS)} commands"
    return (f"postmortem ({reason}): {state}{failure}; "
            f"see {walk_log} and {swd_log}")
