"""GitHub issue #845: the one way a negative control patches text.

A control that plants a defect by replacing the first occurrence of a
string silently retargets when an earlier copy appears: #843 put a new
block_device_wait_count(0) above the report gate that
check_peer_filesystem_controls.py meant to break, and the control broke the
new call instead. replace_once refuses an anchor that does not occur
exactly once, naming it, so the control fails at its own anchor rather
than proving something else. scripts/check_control_replace_once.py
requires every control to patch through here.

An anchor is found by layout_text (#1311), so moving a newline or an indent in
the source does not unmoor a control.
"""

from layout_text import AnchorCountError, layout_count, layout_replace_once


class ControlAnchorError(RuntimeError):
    pass


def replace_once(text: str, old: str, new: str, where: str = "") -> str:
    try:
        return layout_replace_once(text, old, new)
    except AnchorCountError as error:
        place = f" in {where}" if where else ""
        raise ControlAnchorError(
            f"control anchor occurs {error} times{place}, not once: {old!r}") from None
