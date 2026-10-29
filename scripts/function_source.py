"""Brace-matching function extraction from .tkb text, for the checks that
still read source (GitHub issue #987 moved it here from
check_model_function_map.py, whose review stamps now come from the
compiler's --facts callgraph.tsv table).

This is a shadow front end: it approximates what the compiler's parser
knows. A check that needs a function's extent, callees or a stable hash of
its body should read scripts/call_graph_table.py instead; the remaining
callers (the probe checks and check_stack_proof_states.py) are later
migrations of GitHub issue #567.
"""

import re

from source_scan import FrozenMap, code_skeleton, per_file


# Unbounded (#808): with maxsize=8 a caller looping over ~170 kernel files
# missed on every one, so each control re-masked the whole tree.
@per_file
def masked_sources(sources: str) -> str:
    """Preserve offsets while masking braces in comments and string literals
    (source_scan's lexer since GitHub issue #818, so a character literal
    such as '"' no longer opens a string)."""
    return code_skeleton(sources)


@per_file
def function_starts(sources: str) -> FrozenMap:
    """Index the source once, retaining the first definition."""
    code = masked_sources(sources)
    starts = {}
    for match in re.finditer(
            r"^(?:private )?(?:inline |noinline )?fn ([a-z][a-z0-9_]*)\(",
            code, re.M):
        starts.setdefault(match[1], (match.start(), match.end()))
    return FrozenMap(starts)


@per_file
def function_body(name: str, sources: str) -> str | None:
    found = function_starts(sources).get(name)
    if found is None:
        return None
    start, position = found
    code = masked_sources(sources)
    depth = 1
    while depth:
        depth += (code[position] == '(') - (code[position] == ')')
        position += 1
    brace = code.index('{', position)
    if code[brace - 1] == '!':
        brace = code.index('{', code.index('}', brace) + 1)
    depth, end = 1, brace + 1
    while depth:
        depth += (code[end] == '{') - (code[end] == '}')
        end += 1
    return sources[start:end]
