#!/usr/bin/env python3
"""Close the retained exception snapshot aliases and publication association.

Existing types reject integer per_cpu indexes and stopped reads without a
complete stop. The manual exception mint is unscoped: nested plain payload
addresses could still escape. This bounded source policy permits only the
actual non-retaining renderer/copy calls, not a general lifetime proof.
"""

from pathlib import Path
import re

from check_process_running_mints import functions
from pass_line import report_pass
from source_scan import code_skeleton, per_file

PATH = 'kernel/arch/arm64/kernel/exception_evidence.tkb'
STORES = ('crash_snapshot_per_core', 'crash_snapshot_capturing_per_core',
          'kernel_ddb_memory_access', 'ddb_stopped_root')
OBSERVED = '&crash_snapshot_per_core[cpu].observed'
ADDRESSES = {
    'crash_snapshot_copy_published':
        'publish_copy(&crash_snapshot_published[core],' + OBSERVED + ')',
    'crash_snapshot_render_core':
        'crash_snapshot_render_from(' + OBSERVED +
        ',crash_snapshot_per_core[cpu].observed.root_slot)',
}
TRACE_ARGS = {
    'crash_snapshot_capture':
        'kernel_process_crash_trace_copy(crash_snapshot_per_core[cpu].capture.traceas[]usize)',
    'crash_console_dispatch_cached':
        'kernel_process_trace_render(crash_snapshot_per_core[cpu].capture.traceas[]usize,crash_snapshot_per_core[cpu].capture.trace_count,',
}


def fields(code, name):
    match = re.search(r'\bstruct(?:\s+publish)?\s+' + name + r'\s*\{([^}]+)\}', code)
    if not match:
        return ()
    return tuple((name, re.sub(r'\s+', '', typ))
                 for name, typ in re.findall(r'(\w+)\s*:\s*([^;]+);', match[1]))


@per_file
def problems(source):
    code = code_skeleton(source)
    found = []
    published = fields(code, 'CrashSnapshot')
    if not published or published[0] != ('valid', 'usize') or fields(code, 'CrashCapture') != published[1:]:
        found.append('capture/publication schemas must match, apart from the publication marker')
    if not re.search(r'\bstruct\s+publish\s+CrashSnapshot\b', code):
        found.append('crash mirror must use the compiler publication protocol')
    for name, header, body in functions(source):
        compact = re.sub(r'\s+', '', body)
        for store in STORES:
            if re.search(r'\b' + store + r'\b(?!\s*\[)', body):
                found.append(f'{name}: no bare per_cpu array alias')
            addresses = len(re.findall(r'&\s*' + store + r'\s*\[', body))
            expected = int(store == STORES[0] and name in ADDRESSES)
            if addresses != expected or (expected and ADDRESSES[name] not in compact):
                found.append(f'{name}: per_cpu payload address must remain in its exact borrowed call')
            if re.search(store + r'\s*\[[^]]+\](?:\s*\.\s*\w+|\s*\[[^]]+\])*\s+as\s*\*', body):
                found.append(f'{name}: no raw pointer decay from per_cpu payload')
        traces = list(re.finditer(r'crash_snapshot_per_core\s*\[[^]]+\]\s*\.\s*capture\s*\.\s*trace\b', body))
        decays = [m for m in traces if not body[m.end():].lstrip().startswith('[')]
        if len(decays) != int(name in TRACE_ARGS) or (decays and TRACE_ARGS[name] not in compact):
            found.append(f'{name}: trace array stays in its exact borrowed call')
        mirror_uses = len(re.findall(r'\bcrash_snapshot_published\b', body))
        expected = {'crash_snapshot_publish': 3, 'crash_snapshot_copy_published': 1}.get(name, 0)
        if mirror_uses != expected:
            found.append(f'{name}: only the publisher/copy helper reach crash mirror storage')
        if name == 'crash_snapshot_publish':
            bindings = re.findall(r'\blet\s+(?:mut\s+)?core\b[^;]*;', body)
            if [re.sub(r'\s+', '', x) for x in bindings] != [
                    'letcore:{0..<KERNEL_MAX_CORESasusize}=cpu_here_index(cpu);']:
                found.append('publisher slot must be derived once from its same CPU authority')
            for field, typ in published[1:]:
                index = '[item]' if typ.startswith('[') else ''
                assignment = f'write.{field}{index}=crash_snapshot_per_core[cpu].capture.{field}{index};'
                if compact.count(assignment) != 1:
                    found.append(f'publisher must copy its own {field} without substitution')
            if compact.count('publish_commit(write,crash_snapshot_per_core[cpu].capture.sequence);') != 1:
                found.append('publisher must commit its own capture sequence')
        if re.search(r'crash_snapshot_capturing_per_core\s*\[[^]]+\]\.active\s*=\s*false', body):
            found.append('terminal capture flag must never rearm a published slot')
    return tuple(found)


def main():
    found = problems(Path(PATH).read_text())
    if found:
        for message in found:
            print('FAIL exception-cpu-snapshots: ' + message)
        return 1
    report_pass('exception-cpu-snapshots',
                'four CPU stores expose only exact borrowed payloads; publication fields match own capture and terminal slots never rearm',
                stores=len(STORES), schemas=2)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
