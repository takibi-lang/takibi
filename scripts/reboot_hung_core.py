"""What a hung-core reboot transcript must show (GitHub issue #980).

The PTY smoke test's restart run starts /lib/hang-core, which pins itself to
CPU 1, makes HUNG_CORE spin with interrupts masked and calls reboot(2). The
kernel's debug stop must reach that core: its mask line names HUNG_CORE as
held and as the core spinning masked when the stop completed.
"""

import re

HUNG_CORE = 2
STOP_LINE = re.compile(
    rb"\nsystem stop: mask=0x([0-9a-f]{16}) masked-spin=(none|cpu[0-9]+)\n")


def hung_core_stop_problems(uart: bytes) -> list[str]:
    """Problems with the restart run's stop evidence; empty when it holds."""
    if b"\nhang-core: " in uart:
        line = uart.split(b"\nhang-core: ", 1)[1].split(b"\n", 1)[0]
        return [f"/lib/hang-core failed: {line.decode('ascii', 'replace')}"]
    found = STOP_LINE.findall(uart)
    if len(found) != 1:
        return [f"expected one system stop mask line, found {len(found)}"]
    mask_text, spin = found[0]
    problems = []
    if int(mask_text, 16) & (1 << HUNG_CORE) == 0:
        problems.append(f"the stop mask 0x{mask_text.decode()} does not hold "
                        f"the masked cpu {HUNG_CORE}")
    if spin != f"cpu{HUNG_CORE}".encode():
        problems.append(f"the stop completed with masked-spin={spin.decode()}, "
                        f"not while cpu {HUNG_CORE} spun masked")
    return problems
