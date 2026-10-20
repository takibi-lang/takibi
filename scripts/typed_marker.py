"""Spell a console marker so the command that prints it never contains it.

GitHub issue #856, generalized by #857. A driver that types `echo MARKER`
into a shell and then waits for MARKER on a line of its own can be answered
by the shell's echo of the command itself: peer-CPU workload lines can split
that echo so a fragment of it -- `MARKER`, or `MARKER` after the prompt --
lands on a line of its own before the command ran. An empty '' pair in the
middle keeps the typed text distinct; only echo's output is MARKER.

scripts/check_typed_markers.py refuses a typed `echo WORD` whose WORD is not
spelled this way, so the shape cannot return.
"""


def typed_marker(marker):
    """Return MARKER (bytes or str) with an empty '' pair in the middle."""
    if len(marker) < 2:
        raise ValueError(f"marker too short to split: {marker!r}")
    middle = len(marker) // 2
    quote = b"''" if isinstance(marker, bytes) else "''"
    return marker[:middle] + quote + marker[middle:]
