"""Per-file source scans cached by content, for checks whose controls mutate
one file at a time.

GitHub issue #808 (after #789's b49c2043). A control set calls the check's
problems() once per planted defect, each over every kernel source with one
file changed. A scan that is not cached re-parses the whole tree per control;
a cache with a small bound (lru_cache(maxsize=8) over ~170 files) misses on
every file and is the same thing. Both pushed members toward the fast gate's
10 s bound under a loaded allcheck.

`per_file` is the one way a check caches such a scan: unbounded, keyed by the
arguments (the file's text, and its path when the result names it), and it
refuses a result that is not hashable. A cached list or dict handed to two
callers is shared state: a caller that appended to it would change the next
control's verdict, which is how a cache could make a control pass wrongly.

scripts/check_source_scan_cache.py requires every check that its controls
import in-process to use this module (or to be reviewed as scanning too
little to need it), and refuses a bounded lru_cache in scripts/.
"""

import functools
import re


class FrozenMap(dict):
    """A dict a per_file scan may return: lookups work, mutation raises.
    Hashed by identity, which is sound because it cannot change."""

    def _refuse(self, *args, **kwargs):
        raise TypeError("FrozenMap is a cached per_file result; copy it to change it")

    __setitem__ = __delitem__ = _refuse
    clear = pop = popitem = setdefault = update = __ior__ = _refuse
    __hash__ = object.__hash__


def _frozen(value) -> bool:
    if isinstance(value, FrozenMap):
        return True
    try:
        hash(value)
    except TypeError:
        return False
    return True


def per_file(function):
    """Cache `function` by its arguments, without bound; its results must be
    hashable (tuples, frozensets, strings) or a FrozenMap, so no
    caller can mutate a value the next control reads."""
    def checked(*args):
        result = function(*args)
        if not _frozen(result):
            raise TypeError(f"{function.__qualname__}: per_file result must be "
                            f"hashable, got {type(result).__name__}")
        return result

    # Checked once per miss, so a hit costs a dict lookup and nothing more.
    cached = functools.lru_cache(maxsize=None)(checked)
    wrapper = functools.wraps(function)(lambda *args: cached(*args))
    wrapper.cache_info = cached.cache_info
    wrapper.cache_clear = cached.cache_clear
    return wrapper


# GitHub issue #815: a check that claims a CODE property must not pass on a
# comment that names the code. One lexer-shaped pass, mirroring
# lib/lexer.mll: `//` to end of line and non-nesting `/* ... */` are
# comments; a "string" or a 'c' character literal is not, even when it
# holds `//` or `/*`.
_TKB_TOKEN = re.compile(
    r'"(?:\\.|[^"\\])*"'          # string literal
    r"|'(?:\\.|[^'\\\n])'"        # character literal, such as '"'
    r"|//[^\n]*"                  # line comment
    r"|/\*.*?(?:\*/|\Z)", re.S)   # block comment (unterminated runs to EOF)


def _blank(match):
    token = match.group(0)
    if token.startswith("//") or token.startswith("/*"):
        return re.sub(r"[^\n]", " ", token)
    return token


def code_only(text: str) -> str:
    """`text` with every Takibi comment blanked to spaces. Newlines and
    offsets are kept, so line numbers and match positions still point
    into the original; string and character literals are kept as written."""
    return _TKB_TOKEN.sub(_blank, text)


def code_skeleton(text: str) -> str:
    """`text` with every comment AND every string or character literal
    blanked to spaces (GitHub issue #818), offsets and newlines kept: for a
    scan that matches braces or parentheses, which a literal such as "{"
    or '(' would otherwise unbalance."""
    return _TKB_TOKEN.sub(lambda match: re.sub(r"[^\n]", " ", match.group(0)),
                          text)


def py_code_only(text: str) -> str:
    """Python source with every `#` comment blanked to spaces, offsets kept
    (GitHub issue #818). Python's own tokenizer decides what a comment is,
    so a `#` inside a string is kept."""
    import io
    import tokenize
    lines = text.splitlines(keepends=True)
    for token in tokenize.generate_tokens(io.StringIO(text).readline):
        if token.type == tokenize.COMMENT:
            row, start = token.start
            _, end = token.end
            line = lines[row - 1]
            lines[row - 1] = line[:start] + " " * (end - start) + line[end:]
    return "".join(lines)


_SH_HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z_0-9]*)\1")


def sh_code_only(text: str) -> str:
    """POSIX shell (or busybox inittab) text with every `#` comment blanked
    to spaces, offsets kept (GitHub issue #818). A `#` starts a comment only
    at the start of a word outside quotes, so `$#`, `${#x}` and "a#b" are
    kept; a here-document body is data and is kept as written."""
    out = list(text)
    index, quote, line_start = 0, None, True
    heredocs = []
    while index < len(text):
        char = text[index]
        if char == "\n":
            line_start = True
            index += 1
            if quote is None and heredocs:
                # Skip each pending here-document body, verbatim.
                for strip_tabs, word in heredocs:
                    while index < len(text):
                        end = text.find("\n", index)
                        end = len(text) if end < 0 else end
                        line = text[index:end]
                        index = end + 1
                        if (line.lstrip("\t") if strip_tabs else line) == word:
                            break
                heredocs = []
            continue
        if quote == "'":
            if char == "'":
                quote = None
        elif quote == '"':
            if char == "\\":
                index += 1
            elif char == '"':
                quote = None
        elif char == "\\":
            index += 1
        elif char in "'\"":
            quote = char
        elif char == "<" and text.startswith("<<", index):
            match = _SH_HEREDOC.match(text, index)
            if match:
                heredocs.append((match.group(0).startswith("<<-"), match.group(2)))
                index = match.end()
                line_start = False
                continue
        elif char == "#" and (line_start or text[index - 1] in " \t;&|()<>"):
            end = text.find("\n", index)
            end = len(text) if end < 0 else end
            out[index:end] = " " * (end - index)
            index = end
            continue
        line_start = False
        index += 1
    return "".join(out)


def compact(text: str) -> str:
    """`text` with comments and every whitespace character outside a
    literal removed, literals kept as written (GitHub issue #818): a
    layout-blind spelling of code, for hashing a function body."""
    out = []
    position = 0
    for match in _TKB_TOKEN.finditer(text):
        out.append(re.sub(r"\s+", "", text[position:match.start()]))
        token = match.group(0)
        if not (token.startswith("//") or token.startswith("/*")):
            out.append(token)
        position = match.end()
    out.append(re.sub(r"\s+", "", text[position:]))
    return "".join(out)
