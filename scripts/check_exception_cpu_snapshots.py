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
MIRROR = 'crash_snapshot_published'
CALLERS = {
    'crash_snapshot_capture': ('el1_exception_evidence', 'el1_exception_evidence_from_frame', 'kernel_invariant_evidence'),
    'crash_world_stop_report': ('crash_snapshot_capture',),
    'crash_snapshot_publish': ('crash_world_stop_report',),
    'crash_snapshot_copy_published': ('crash_snapshot_render_every_core', 'crash_snapshot_render_core'),
    'crash_snapshot_render_from': ('crash_snapshot_render_core',),
}

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
                 for name, typ in re.findall(r'(\w+)\s*:\s*(\[[^]]+\]|[^;]+);', match[1]))


def publisher_body(schema):
    """Exact small writer, generated from the independently checked schema."""
    parts = ['{let core:{0..<KERNEL_MAX_CORES as usize}=cpu_here_index(cpu);',
             'let write=publish_begin(&crash_snapshot_published[core]);']
    for field, typ in schema[1:]:
        if typ.startswith('['):
            bound = typ[1:-1].split(';', 1)[1]
            parts.append('for item:usize in 0..<' + bound + '{write.' + field +
                         '[item]=crash_snapshot_per_core[cpu].capture.' + field + '[item];}')
        else:
            parts.append('write.' + field + '=crash_snapshot_per_core[cpu].capture.' + field + ';')
    parts.extend([
        'dma_prepare_tx((&crash_snapshot_published[core]) as *usize,sizeof(CrashSnapshot));',
        'publish_commit(write,crash_snapshot_per_core[cpu].capture.sequence);',
        'dma_prepare_tx((&crash_snapshot_published[core]) as *usize,sizeof(usize));',
        'crash_report_claim();crash_snapshot_render(cpu);crash_report_release();}'])
    return re.sub(r'\s+', '', ''.join(parts))


# Reviewed success-before-read adapters; changes require explicit policy review.
CLOSED_ADAPTERS = {
    'crash_snapshot_render_every_core': '{letmutrendered:usize=0;letmutprevious:usize=0;forround:usizein0..<KERNEL_MAX_CORES{letmutbest_core:usize=KERNEL_MAX_CORES;letmutbest_order:usize=0;forcore:usizein0..<KERNEL_MAX_CORES{matchcrash_snapshot_copy_published(cpu,core){CrashSnapshotReadResult::Unpublished=>{continue;}CrashSnapshotReadResult::Ready=>{}}letorder:usize=crash_snapshot_per_core[cpu].observed.fault_order;if(order<=previous){continue;}if(best_core==KERNEL_MAX_CORES||order<best_order){best_core=core;best_order=order;}}letchosen:usize=best_core;if(chosen<KERNEL_MAX_CORES){previous=best_order;if(crash_snapshot_render_core(cpu,chosen)){rendered=rendered+1;}}else{break;}}ddb_puts();ddb_put_udec(rendered);ddb_puts();ddb_put_udec(atomic_word_load(&crash_fault_order));ddb_puts();ddb_put_udec(atomic_word_load(&crash_report_contended));ddb_puts();ddb_put_udec(atomic_word_load(&crash_report_abandoned));ddb_puts();}',
    'crash_snapshot_copy_published': '{lettaken:usize=publish_copy(&crash_snapshot_published[core],&crash_snapshot_per_core[cpu].observed);if(taken==0){returnCrashSnapshotReadResult::Unpublished;}returnCrashSnapshotReadResult::Ready;}',
    'crash_snapshot_render_core': '{matchcrash_snapshot_copy_published(cpu,core){CrashSnapshotReadResult::Unpublished=>{returnfalse;}CrashSnapshotReadResult::Ready=>{crash_snapshot_render_from(&crash_snapshot_per_core[cpu].observed,crash_snapshot_per_core[cpu].observed.root_slot);returntrue;}}}',
}

# Exactly one publication in each disjoint stop-result arm.
CLOSED_ADAPTERS['crash_world_stop_report'] = '{matchworld_stop_debug_begin(DDB_WORLD_STOP_SPINS){MachineStopResult::Busy=>{crash_report_claim();ddb_puts();ddb_puts();crash_report_release();crash_snapshot_publish(cpu);if(crash_console_claim()){crash_console_run(cpu);}}MachineStopResult::Partial(partial)=>{letmask:usize=machine_stop_partial_mask(partial);machine_stop_partial_release(partial,&kernel_world_stop);crash_report_claim();ddb_puts();ddb_puts();ddb_put_hex(mask);ddb_puts();crash_report_release();crash_snapshot_publish(cpu);if(crash_console_claim()){crash_console_run(cpu);}}MachineStopResult::Complete(stopped)=>{letmask:usize=machine_stopped_mask(stopped);crash_report_claim();ddb_puts();ddb_puts();ddb_put_hex(mask);ddb_puts();crash_report_release();if(origin==1&&frame_sp!=0&&kernel_process_crash_frame_usable(stopped,cpu,frame_sp)){crash_snapshot_capture_frame(cpu,frame_ref_from_entry(frame_sp,kernel_process_stopped_entry_generation(cpu)));crash_snapshot_per_core[cpu].capture.saved_frame_available=1;}crash_snapshot_shared_stopped(cpu,stopped);crash_snapshot_publish(cpu);if(crash_console_claim()){crash_console_run_stopped(cpu,stopped);}machine_stop_keep_forever(stopped);}}}'


CAPTURE_PREFIX = re.sub(r'\s+', '', """{
    let mut cpu:CpuHere=exception_cpu_here();
    kernel_log_enter_emergency();
    if(crash_snapshot_capturing_per_core[cpu].active){
        ddb_puts();while(true){interrupt_wait();}
    }
    crash_snapshot_capturing_per_core[cpu].active=true;
""")


@per_file
def problems(source):
    code = code_skeleton(source)
    found = []
    declarations = re.findall(r'(?:private\s+)?let\s+mut\s+' + MIRROR + r'\s*:\s*\[[^]]+\]\s*;', code)
    if [re.sub(r'\s+', '', x) for x in declarations] != [
            'privateletmutcrash_snapshot_published:[CrashSnapshot;KERNEL_MAX_CORES];']:
        found.append('mirror must remain its exact private published array')
    published = fields(code, 'CrashSnapshot')
    if not published or published[0] != ('valid', 'usize') or fields(code, 'CrashCapture') != published[1:]:
        found.append('capture/publication schemas must match, apart from the publication marker')
    if not re.search(r'\bstruct\s+publish\s+CrashSnapshot\b', code):
        found.append('crash mirror must use the compiler publication protocol')
    bodies = list(functions(source))
    function_uses = sum(len(re.findall(r'\b' + MIRROR + r'\b', body)) for _, _, body in bodies)
    if len(re.findall(r'\b' + MIRROR + r'\b', code)) != 1 + function_uses:
        found.append('mirror storage has no use outside its declaration and reviewed function bodies')
    for required in {*CALLERS, *CLOSED_ADAPTERS}:
        if sum(name == required for name, _, _ in bodies) != 1:
            found.append(f'{required}: policy requires exactly one reviewed adapter')
    for name, header, body in bodies:
        compact = re.sub(r'\s+', '', body)
        if name in CLOSED_ADAPTERS and compact != CLOSED_ADAPTERS[name]:
            found.append(f'{name}: publication adapter must retain its exact checked protocol body')
        if '.observed' in compact and name not in CLOSED_ADAPTERS:
            found.append(f'{name}: observed payload belongs only to checked reader adapters')
        for store in STORES:
            if re.search(r'\b' + store + r'\b(?!\s*\[)', body):
                found.append(f'{name}: no bare per_cpu array alias')
            addresses = len(re.findall(r'&\s*\(*\s*' + store + r'\s*\[', body))
            expected = int(store == STORES[0] and name in ADDRESSES)
            if addresses != expected or (expected and ADDRESSES[name] not in compact):
                found.append(f'{name}: per_cpu payload address must remain in its exact borrowed call')
            if re.search(store + r'\s*\[[^]]+\](?:\s*\.\s*\w+|\s*\[[^]]+\])*\s+as\s*\*', body):
                found.append(f'{name}: no raw pointer decay from per_cpu payload')
        for section in ('capture', 'observed'):
            for field, typ in published[1:]:
                if not typ.startswith('['):
                    continue
                accesses = list(re.finditer(
                    r'crash_snapshot_per_core\s*\[[^]]+\]\s*\.\s*' + section +
                    r'\s*\.\s*' + field + r'\b', body))
                decays = [m for m in accesses if not body[m.end():].lstrip().startswith('[')]
                allowed = section == 'capture' and field == 'trace' and name in TRACE_ARGS
                if len(decays) != int(allowed) or (allowed and TRACE_ARGS[name] not in compact):
                    found.append(f'{name}: {section}.{field} array stays in its exact borrowed call')
        traces = list(re.finditer(r'crash_snapshot_per_core\s*\[[^]]+\]\s*\.\s*capture\s*\.\s*trace\b', body))
        decays = [m for m in traces if not body[m.end():].lstrip().startswith('[')]
        if len(decays) != int(name in TRACE_ARGS) or (decays and TRACE_ARGS[name] not in compact):
            found.append(f'{name}: trace array stays in its exact borrowed call')
        mirror_uses = len(re.findall(r'\bcrash_snapshot_published\b', body))
        expected = {'crash_snapshot_publish': 3, 'crash_snapshot_copy_published': 1}.get(name, 0)
        if mirror_uses != expected:
            found.append(f'{name}: only the publisher/copy helper reach crash mirror storage')
        if name == 'crash_snapshot_publish' and compact != publisher_body(published):
            found.append('publisher must exactly copy its own fields and commit its same CPU slot')
        flag_writes = re.findall(
            r'crash_snapshot_capturing_per_core\s*\[[^]]+\]\s*\.\s*active\s*(?:[+*/&|^-]?=)(?!=)[^;]*;', body)
        expected_writes = ['crash_snapshot_capturing_per_core[cpu].active=true;'] if name == 'crash_snapshot_capture' else []
        if [re.sub(r'\s+', '', x) for x in flag_writes] != expected_writes:
            found.append('terminal capture flag has only its single canonical true write')
        if name == 'crash_snapshot_capture' and not compact.startswith(CAPTURE_PREFIX):
            found.append('terminal capture must park recursive entries before any payload write')
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
