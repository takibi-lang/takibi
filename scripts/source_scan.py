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
