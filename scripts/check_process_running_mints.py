#!/usr/bin/env python3
"""Check current-process witness mints and context/phase-change markers.

The type checker enforces witness consumption. This source check keeps the
private physical mint boundary and context/phase writer annotation inventory closed.
It does not prove physical generation association or remote CPU protocols.
"""

from collections import Counter
from functools import lru_cache
import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path("kernel")
ALLOWED = {
    "process_running_here": Counter({
        "kernel_process_fanout_probe": 3,
        "kernel_process_trace_block_wake_probe": 2,
        "syscall_vectored_prefix_wait_probe": 3,
        # GitHub issue #202: boot probes that check a user range after the
        # dispatch they exercise take the boot process's authority for it.
        "syscall_vectored_inetd_probe": 4,
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


@lru_cache(maxsize=64)
def mask(source):
    return re.sub(r'//[^\n]*|"(?:\\.|[^"\\])*"',
                  lambda m: re.sub(r'[^\n]', ' ', m[0]), source)


def functions(source):
    code = mask(source)
    for match in re.finditer(r'^(?:private )?(?:inline |noinline )?fn (\w+)\(', code, re.M):
        depth, pos = 1, match.end()
        while depth:
            depth += (code[pos] == '(') - (code[pos] == ')')
            pos += 1
        brace = code.index('{', pos)
        if code[brace - 1] == '!':
            brace = code.index('{', code.index('}', brace) + 1)
        depth, end = 1, brace + 1
        while depth:
            depth += (code[end] == '{') - (code[end] == '}')
            end += 1
        yield match[1], code[match.start():brace], code[brace:end]


@lru_cache(maxsize=64)
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
    for mint in ALLOWED:
        pattern = (r'\bview\s+ProcessCurrent\s*\[' if mint.startswith('view ')
                   else rf'\b{mint}\s*\(')
        totals[mint] += len(re.findall(pattern, code))
    for name, header, body in functions(source):
        declarations[name] += 1
        for mint in ALLOWED:
            pattern = (r'\bview\s+ProcessCurrent\s*\[' if mint.startswith('view ')
                       else rf'\b{mint}\s*\(')
            # Most functions contain none of these five mint names. Avoid
            # scanning their whole bodies once for every absent name.
            needle = "ProcessCurrent" if mint.startswith('view ') else mint
            if needle in body:
                found[mint][name] += len(re.findall(pattern, body))
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
    return found, totals, declarations, tuple(failures)


def problems(sources):
    found = {name: Counter() for name in ALLOWED}
    failures = []
    totals = Counter()
    declarations = Counter()
    process_source = sources["kernel/kernel/process.tkb"]
    if not re.search(r'^private linear view ProcessCurrent\[', mask(process_source), re.M):
        failures.append("ProcessCurrent must remain private and linear")
    for path, source in sources.items():
        if not re.search(r"\b(?:ProcessCurrent|process_running_here|process_constructing_here|"
                         r"process_running_new|process_constructing_new|ScheduledProcessState)\b|"
                         r"\.current_(?:handle|live)\s*=", source):
            continue
        local_found, local_totals, local_declarations, local_failures = source_facts(source)
        for mint in ALLOWED:
            found[mint].update(local_found[mint])
        totals.update(local_totals)
        declarations.update(local_declarations)
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
