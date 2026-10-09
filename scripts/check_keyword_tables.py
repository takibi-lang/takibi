#!/usr/bin/env python3
"""Keep the lexer's keyword table and Language_words.hard_keywords equal.

lib/lexer.mll turns an identifier into a keyword token only when
Language_words.is_hard_keyword says it is one, then maps it with
hard_keyword_token. A word the lexer maps but the list omits is silently an
IDENT, and the grammar reports a bare "Syntax error" at the next token --
which is how `struct per_cpu` first failed (GitHub issue #704). A word the
list has but the lexer omits fails at run time instead. Both directions are
checked here, from the two source tables.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent


def lexer_words(text):
    start = text.index("let hard_keyword_token = function")
    end = text.index("| word -> failwith", start)
    return set(re.findall(r'"([a-z_0-9]+)"\s*->', text[start:end]))


def list_words(text):
    start = text.index("let hard_keywords = [")
    end = text.index("]", start)
    return set(re.findall(r'"([a-z_0-9]+)"', text[start:end]))


def main():
    lexer = lexer_words((ROOT / "lib" / "lexer.mll").read_text())
    listed = list_words((ROOT / "lib" / "language_words.ml").read_text())
    problems = []
    for word in sorted(lexer - listed):
        problems.append(f"'{word}' has a lexer token but is not in "
                        "Language_words.hard_keywords: it lexes as an identifier")
    for word in sorted(listed - lexer):
        problems.append(f"'{word}' is in Language_words.hard_keywords but has "
                        "no lexer token")
    if problems:
        for problem in problems:
            print(f"ERROR keyword-tables: {problem}")
        sys.exit(1)
    report_pass("keyword-tables",
                f"{len(lexer)} hard keywords agree between lib/lexer.mll and "
                "lib/language_words.ml", keywords=len(lexer))


if __name__ == "__main__":
    main()
