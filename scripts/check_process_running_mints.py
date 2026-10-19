#!/usr/bin/env python3
"""Check current-process witness mints and context/phase-change markers.

The type checker enforces witness consumption. This source check keeps the
private physical mint boundary and context/phase writer annotation inventory closed.
It does not prove physical generation association or remote CPU protocols.
"""

from collections import Counter
import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_skeleton, per_file

ROOT = pathlib.Path("kernel")
ALLOWED = {
    "process_running_here": Counter({
        "kernel_process_fanout_probe": 3,
        "kernel_process_trace_block_wake_probe": 2,
        "syscall_vectored_prefix_wait_probe": 3,
        # GitHub issue #202: boot probes that check a user range after the
        # dispatch they exercise take the boot process's authority for it.
        "syscall_vectored_connected_read_probe": 2,
        "kernel_syscall_subset_probe": 2,
        "process_image_exec_resume_root": 1,
        "kernel_process_timer_schedule": 1,
        "kernel_process_syscall_return_schedule": 1,
        "kernel_process_exit_waiter_probe": 1,
        "kernel_process_scheduler_probe": 1,
        "kernel_syscall_block_return": 1,
        "kernel_syscall_child_exec_return": 1,
        "kernel_syscall_dispatch_action": 1,
    }),
    "process_constructing_here": Counter({"kernel_syscall_clone_child_return": 1}),
    "process_running_new": Counter({"process_running_here": 1,
                                    "kernel_process_clone_rollback": 1}),
    "process_constructing_new": Counter({"process_constructing_here": 1,
                                         "kernel_process_clone_begin": 1}),
    # GitHub issue #202: process_resuming_new is the exit handoff's resume of
    # its successor, a return boundary, for the wait4 status write.
    "process_resuming_new": Counter({"kernel_process_exit_reserved": 1}),
    "view ProcessCurrent": Counter({"process_running_new": 1,
                                     "process_resuming_new": 1,
                                     "process_constructing_new": 1,
                                     "kernel_process_clone_context_install": 2,
                                     "kernel_process_clone_unselectable_probe": 1}),
}


@per_file
def mask(source):
    """Comments (block comments too) and literals blanked, offsets kept:
    source_scan's lexer since GitHub issue #818."""
    return code_skeleton(source)


def closers(code):
    """Position just past the bracket closing each ( and { in `code`.

    One regex pass with a stack instead of a character loop per function:
    the controls re-analyse process.tkb once per mutation, and the loop made
    them slow enough to overrun the fast gate on a loaded host (GitHub
    issue #780)."""
    close, stack = {}, []
    for m in re.finditer(r'[(){}]', code):
        if m[0] in '({':
            stack.append(m.start())
        elif stack:
            close[stack.pop()] = m.end()
    return close


def functions(source):
    code = mask(source)
    close = closers(code)
    for match in re.finditer(r'^(?:private )?(?:inline |noinline )?fn (\w+)\(', code, re.M):
        pos = close[match.end() - 1]
        brace = code.index('{', pos)
        if code[brace - 1] == '!':
            brace = code.index('{', code.index('}', brace) + 1)
        end = close[brace]
        yield match[1], code[match.start():brace], code[brace:end]


@per_file
def function_facts(name, header, body):
    """One function's mint counts and failures, cached by its text: a
    mutation control changes one function of process.tkb, so the others are
    not re-scanned (GitHub issue #780)."""
    counts = []
    failures = []
    for mint in ALLOWED:
        pattern = (r'\bview\s+ProcessCurrent\s*\[' if mint.startswith('view ')
                   else rf'\b{mint}\s*\(')
        # Most functions contain none of these five mint names. Avoid
        # scanning their whole bodies once for every absent name.
        needle = "ProcessCurrent" if mint.startswith('view ') else mint
        if needle in body:
            counts.append((mint, len(re.findall(pattern, body))))
    writes = re.search(r'\.current_(?:handle|live)\s*=(?!=)', body)
    leaves_phase = re.search(
        r'\bsink\s+ScheduledProcessState\[\w+,\s*'
        r'ProcessState::(?:Running|Constructing)\]', header)
    # The record's state changes only through process_wait.tkb's
    # transitions; process_state_kind is the one reader.
    changes_state = re.search(
        r'\.state\s*=(?!=)|\bprocess_state_(?!kind\b)\w+\s*\(', body)
    if (writes or name in {"kernel_process_clone_context_install",
                           "kernel_process_clone_unselectable_probe",
                           "scheduled_process_release_every_process"}
            or (leaves_phase and changes_state)):
        if "changes_witness_ProcessCurrent" not in header:
            failures.append(f"{name} changes current context without its witness marker")
    if name in {"process_running_new", "process_constructing_new",
                "process_resuming_new"}:
        if not header.startswith("private inline fn "):
            failures.append(f"{name} must remain a private inline mint")
    return tuple(counts), tuple(failures)


@per_file
def source_facts(source):
    """Cache by complete content, so mutation controls reuse unchanged files.

    Facts are only read by problems; aggregate counters are fresh each time.
    Changed source text always gets a separate analysis.
    """
    found = {name: Counter() for name in ALLOWED}
    totals = Counter()
    declarations = Counter()
    failures = []
    code = mask(source)
    declarations["view ProcessCurrent"] += len(re.findall(
        r"^private linear view ProcessCurrent\[", code, re.M))
    # A leading \b makes the regex engine try every position; matching the
    # name first and checking the boundary by hand is ~25x faster (#780).
    for mint, pattern in TOTALS_PATTERNS:
        totals[mint] += sum(1 for m in pattern.finditer(code)
                            if m.start() == 0 or not (code[m.start() - 1].isalnum()
                                                      or code[m.start() - 1] == '_'))
    for name, header, body in functions(source):
        declarations[name] += 1
        counts, function_failures = function_facts(name, header, body)
        for mint, count in counts:
            found[mint][name] += count
        failures.extend(function_failures)
    # Frozen (#808): a cached result is shared by every control.
    return (tuple((mint, tuple(found[mint].items())) for mint in ALLOWED),
            tuple(totals.items()), tuple(declarations.items()), tuple(failures))


TOTALS_PATTERNS = [
    (mint, re.compile(r'view\s+ProcessCurrent\s*\[' if mint.startswith('view ')
                      else rf'{mint}\s*\('))
    for mint in ALLOWED]
RELEVANT = re.compile(
    r"\b(?:ProcessCurrent|process_running_here|process_constructing_here|"
    r"process_running_new|process_constructing_new|ScheduledProcessState)\b|"
    r"\.current_(?:handle|live)\s*=")


@per_file
def relevant(source):
    """Whether a file can hold a mint or a context writer; cached by content,
    so a mutation control rescans only the file it changed (#780)."""
    return RELEVANT.search(source) is not None


def problems(sources):
    found = {name: Counter() for name in ALLOWED}
    failures = []
    totals = Counter()
    declarations = Counter()
    process_source = sources["kernel/kernel/process.tkb"]
    if not re.search(r'^private linear view ProcessCurrent\[', mask(process_source), re.M):
        failures.append("ProcessCurrent must remain private and linear")
    for path, source in sources.items():
        if not relevant(source):
            continue
        local_found, local_totals, local_declarations, local_failures = source_facts(source)
        for mint, items in local_found:
            found[mint].update(dict(items))
        totals.update(dict(local_totals))
        declarations.update(dict(local_declarations))
        failures.extend(f"{path}: {failure}" for failure in local_failures)
    for mint, expected in ALLOWED.items():
        actual = +found[mint]
        if totals[mint] != actual.total() + declarations[mint]:
            failures.append(f"{mint} occurs outside a reviewed function body")
        if actual != expected:
            failures.append(f"{mint} callers differ: expected {dict(expected)}, found {dict(actual)}")
    return failures


def main():
    sources = {str(path): path.read_text() for path in sorted(ROOT.rglob('*.tkb'))
               if 'build' not in path.parts}
    failures = problems(sources)
    for failure in failures:
        print('FAIL process-running-mints: ' + failure, file=sys.stderr)
    if failures:
        return 1
    report_pass('process-running-mints',
                'current witness mints and context writer markers match the reviewed boundary',
                files=len(sources))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
