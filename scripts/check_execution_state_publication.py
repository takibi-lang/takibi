#!/usr/bin/env python3
"""Close the ExecutionState placement writer set and its trace publication.

The owning CPU's four placement fields change only in the small guarded
setters. Each setter publishes before returning, through the same CpuHere.
This is a source-shape check at that trust boundary, not a proof of arbitrary
control flow or a substitute for the kernel trace and PID-zero regression.
"""

from pathlib import Path
import re
import sys

from pass_line import report_pass
from source_scan import code_skeleton, function_header, per_file
from check_lock_rank_wrappers import body_start

SOURCE = Path('kernel/kernel/process.tkb')
SETTERS = {
    'execution_current_set_handle': ('current_handle', 'execution_current_publish'),
    'execution_current_set_live': ('current_live', 'execution_current_publish'),
    'execution_stack_set_handle': ('stack_handle', 'execution_stack_publish'),
    'execution_stack_set_live': ('stack_live', 'execution_stack_publish'),
}
FIELDS = '|'.join(field for field, _ in SETTERS.values())
WRITE = re.compile(r'\.\s*(' + FIELDS + r')\s*(?:[-+*/%|&^]|<<|>>)?=(?!=)')
HEADER = function_header()


@per_file
def functions(text):
    code = code_skeleton(text)
    found = []
    for hit in HEADER.finditer(code):
        start = body_start(code, hit.end())
        if start is None:
            continue
        depth, end = 1, start + 1
        while depth and end < len(code):
            depth += {'{': 1, '}': -1}.get(code[end], 0)
            end += 1
        found.append((hit[1], code[hit.start():end]))
    return tuple(found)


def problems(text):
    bodies = dict(functions(text))
    errors = []
    publication_functions = {'execution_current_publish', 'execution_stack_publish',
                             'execution_observed_current_pid', 'execution_observed_stack_pid'}
    for name, body in bodies.items():
        if re.search(r'\bexecution_observation\s*\.', body) and name not in publication_functions:
            errors.append(f'{name}: publication storage is private to its publishers/readers')
        writes = tuple(hit[1] for hit in WRITE.finditer(body))
        expected = (SETTERS[name][0],) if name in SETTERS else ()
        if writes != expected:
            errors.append(f'{name}: placement writes {writes}, expected {expected}')
    for name, (field, publish) in SETTERS.items():
        body = re.sub(r'\s+', '', bodies.get(name, ''))
        tail = f'.{field}='
        at = body.find(tail)
        # These intentionally tiny setters are straight-line: a conditional
        # or early return after their write requires reviewing this boundary.
        wanted = rf'\.{field}=[^;]+;{publish}\(guard,cpu\);\}}$'
        if at < 0 or re.search(wanted, body[at:]) is None:
            errors.append(f'{name}: write must be followed directly by {publish}')
        if 'cpu:CpuHere' not in body or f'execution_state[cpu].{field}=' not in body:
            errors.append(f'{name}: index the typed store directly by its CpuHere')
    for kind in ('current', 'stack'):
        name = f'execution_{kind}_publish'
        body = re.sub(r'\s+', '', bodies.get(name, ''))
        if 'cpu_here_index(cpu)' not in body or 'cpu:CpuHere)' not in body:
            errors.append(f'{name}: derive its index internally from CpuHere')
        if f'execution_observation.{kind}_live)' not in body:
            errors.append(f'{name}: publish the live bit independently of PID zero')
        reader = re.sub(r'\s+', '', bodies.get(f'execution_observed_{kind}_pid', ''))
        if (f'if(guarded_ref(guard,execution_observation.{kind}_live)[core])' not in reader
                or f'returnguarded_ref(guard,execution_observation.{kind}_pid)[core];' not in reader
                or 'returnPROTOCOL_TRACE_NONE;' not in reader):
            errors.append(f'{kind} reader: preserve live PID zero and absent separately')
    return errors


def controls(text):
    cases = [
        ('foreign writer', text + '\nfn foreign() { execution_state[index].current_live = false; }'),
        ('alias writer', text + '\nfn foreign() { state.stack_live = false; }'),
        ('foreign publication', text + '\nfn foreign() { guarded_ref(guard, execution_observation.current_pid)[core] = 0; }'),
        ('compound writer', text + '\nfn foreign() { state.current_live |= true; }'),
        ('omitted publication', text.replace('execution_current_publish(guard, cpu);', '', 1)),
        ('conditional publication', text.replace('execution_stack_publish(guard, cpu);',
                                               'if (live) { execution_stack_publish(guard, cpu); }', 1)),
        ('independent index', text.replace('let index: {0..<KERNEL_MAX_CORES as usize} = cpu_here_index(cpu);',
                                         'let index: {0..<KERNEL_MAX_CORES as usize} = core;', 1)),
        ('zero sentinel', text.replace('if (guarded_ref(guard, execution_observation.current_live)[core])',
                                      'if (guarded_ref(guard, execution_observation.current_pid)[core] != 0)', 1)),
    ]
    for label, planted in cases:
        if planted == text or not problems(planted):
            raise ValueError(f'control not refused: {label}')
    harmless = text + '\nfn equality_only() { if (state.current_live == false) {} }\n'
    if problems(harmless) or problems(text + '\n// state.current_live = false;\n'):
        raise ValueError('equality or comment was treated as a write')
    return len(cases) + 2


def main():
    text = SOURCE.read_text(encoding='ascii')
    errors = problems(text)
    if errors:
        for error in errors:
            print(f'ERROR execution-state-publication: {error}')
        return 1
    count = controls(text)
    report_pass('execution-state-publication',
                f'{len(SETTERS)} placement writers publish through their authority; '
                f'live PID zero is distinct from absence; {count} controls',
                writers=len(SETTERS), controls=count)
    return 0


if __name__ == '__main__':
    sys.exit(main())
