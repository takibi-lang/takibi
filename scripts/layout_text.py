"""Find .tkb text by its tokens' spelling, whatever its layout (GitHub issue #1311).

A script that holds an exact piece of kernel source -- an overlay's anchor, a
control's plant site, a required shape -- breaks when `takibi fmt` moves a
newline or an indent, although the program did not change. Here any run of
whitespace in the needle matches any run of whitespace in the text. Token
order and spelling still have to agree.
"""

import re


class AnchorCountError(RuntimeError):
    pass


def layout_pattern(needle: str) -> re.Pattern:
    """A run with a newline, or inside the needle, spans any whitespace. An
    indent or trailing space at the needle's edge may be any spaces, and a
    leading one still has to start a word, so `    x: u8` does not find `ax: u8`
    and the match does not swallow the previous line's comment."""
    parts = re.split(r"(\s+)", needle)
    out = []
    for index, part in enumerate(parts):
        if index % 2 == 0:
            out.append(re.escape(part))
        elif index == 1 and not parts[0] and "\n" not in part:
            out.append(r"(?<!\S)[ \t]*")
        elif index == len(parts) - 2 and not parts[-1] and "\n" not in part:
            out.append(r"[ \t]*")
        else:
            out.append(r"\s+")
    return re.compile("".join(out))


def layout_count(text: str, needle: str) -> int:
    exact = text.count(needle)
    if exact:
        return exact
    return sum(1 for _ in layout_pattern(needle).finditer(text))


def layout_replace_once(text: str, old: str, new: str) -> str:
    """Replace the one occurrence; AnchorCountError names any other count."""
    count = layout_count(text, old)
    if count != 1:
        raise AnchorCountError(str(count))
    if old in text:
        return text.replace(old, new, 1)
    return layout_pattern(old).sub(lambda _: new, text, count=1)


class LayoutSource(str):
    """Source whose `in` and `.count` use layout_count, for a check that holds
    many required shapes: wrap the text once and leave each test as written."""

    def __contains__(self, needle):
        return layout_count(self, needle) > 0

    def count(self, needle, *args):
        return layout_count(str(self), needle) if not args else str.count(self, needle, *args)
