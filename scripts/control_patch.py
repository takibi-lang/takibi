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


def replace_in_function(text: str, header: str, old: str, new: str) -> str:
    """GitHub issue #904: patch `old` inside one function only.

    `header` (for example "fn name(") must occur once; `old` must occur
    exactly once between it and the function's closing "\\n}\\n", so code
    inserted after the function can never become the target.
    """
    start = layout_text_find_once(text, header)
    end = text.find("\n}\n", start)
    if end < 0:
        raise ControlAnchorError(f"no closing brace after {header!r}")
    body = replace_once(text[start:end], old, new, where=header)
    return text[:start] + body + text[end:]


def layout_text_find_once(text: str, header: str) -> int:
    count = text.count(header)
    if count != 1:
        raise ControlAnchorError(
            f"function header occurs {count} times, not once: {header!r}")
    return text.index(header)
