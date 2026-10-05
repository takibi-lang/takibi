#!/usr/bin/env python3
"""Build isolated real-kernel retention variants; never edit production sources."""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('source premise changed: '+old[:80])
    return text.replace(old, new, 1)


def instrument(text, retain):
    for pool, ty, pages in [('fd_block', 'FdBlock', 'FD_BLOCK_CHUNK_PAGES'), ('object', 'SharedObject', 'OBJECT_CHUNK_PAGES')]:
        prefix = 'retention_'+pool
        text += '\n// Experimental counters; each access holds the matching production pool guard.\n'
        for name in ('grows', 'shrinks', 'grow_ticks', 'shrink_ticks'):
            text += f'private let mut {prefix}_{name}: usize;\n'
        start = text.index(f'private fn {pool}_return_empty(')
        stop = text.index(f'private fn {pool}_slot_free(', start)
        body = text[start:stop]
        if body.count('region_pool_empty_chunks(guard) > 1') != 2:
            raise ValueError('retention premise changed')
        body = body.replace('region_pool_empty_chunks(guard) > 1', f'region_pool_empty_chunks(guard) > {retain}')
        body = replace_once(body, 'let address: usize = region_bytes_address(bytes);', 'let started: usize = read_cntpct() as usize;\n                let address: usize = region_bytes_address(bytes);')
        anchor = f'page_run_transferred_release_physical(address, {pages});'
        body = replace_once(body, anchor, anchor+f'\n                {prefix}_shrinks = {prefix}_shrinks + 1;\n                {prefix}_shrink_ticks = {prefix}_shrink_ticks + ((read_cntpct() as usize) - started);')
        text = text[:start]+body+text[stop:]
        start = text.index(f'private fn {pool}_pool_grow(')
        stop = text.index('\n}\n', start)+3
        body = text[start:stop]
        anchor = f'    match page_alloc_contiguous({pages}, PageOwnerTag::PoolChunk)'
        body = replace_once(body, anchor, '    let started: usize = read_cntpct() as usize;\n'+anchor)
        anchor = f'RegionGrow({ty})::Grown => {{ return true; }}'
        body = replace_once(body, anchor, f'RegionGrow({ty})::Grown => {{\n                    {prefix}_grows = {prefix}_grows + 1;\n                    {prefix}_grow_ticks = {prefix}_grow_ticks + ((read_cntpct() as usize) - started);\n                    return true;\n                }}')
        text = text[:start]+body+text[stop:]
        text += f'''
private fn {prefix}_report(phase: *u8) !{{unsafe}} {{
    let guard = {pool}_pool_lock(&{pool}_pool);
    let grows: usize = {prefix}_grows;
    let shrinks: usize = {prefix}_shrinks;
    let grow_ticks: usize = {prefix}_grow_ticks;
    let shrink_ticks: usize = {prefix}_shrink_ticks;
    let (chunks, capacity, live, bytes) = region_pool_space_stats(guard);
    {pool}_pool_unlock(guard);
    kernel_boot_log("retention stats: phase="); kernel_boot_log(phase);
    kernel_boot_log(" pool={pool} retain={retain} grows="); uart_put_udec(grows);
    kernel_boot_log(" shrinks="); uart_put_udec(shrinks);
    kernel_boot_log(" grow_ticks="); uart_put_udec(grow_ticks);
    kernel_boot_log(" shrink_ticks="); uart_put_udec(shrink_ticks);
    kernel_boot_log(" chunks="); uart_put_udec(chunks);
    kernel_boot_log(" capacity="); uart_put_udec(capacity);
    kernel_boot_log(" live="); uart_put_udec(live);
    kernel_boot_log(" bytes="); uart_put_udec(bytes);
    kernel_boot_log(" frequency="); uart_put_udec(read_cntfrq() as usize);
    kernel_boot_log("\\n");
}}
'''
    return text+'\nfn retention_report(phase: *u8) !{unsafe} {\n    retention_fd_block_report(phase);\n    retention_object_report(phase);\n}\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--retain', type=int, choices=(0, 1), required=True)
    parser.add_argument('--platform', choices=('qemu', 'rpi5'), required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    if out.is_relative_to(ROOT/'kernel'):
        parser.error('output must be outside the source kernel tree')
    if out.exists():
        parser.error('output must be a new directory')
    out.mkdir(parents=True)
    files = [ROOT/'kernel/kernel/fd_table.tkb', ROOT/'kernel/init/test_driver.tkb', ROOT/'kernel/init/pool_space.tkb', HERE/'prepare.py', HERE/'workload.c', ROOT/'kernel/benchmarks/service_space/workload.c']
    provenance = {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'retain': args.retain, 'platform': args.platform, 'sha256': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}}
    (out/'provenance.json').write_text(json.dumps(provenance, indent=2)+'\n')
    shutil.copytree(ROOT/'kernel', out/'kernel', ignore=shutil.ignore_patterns('build'))
    build = out/'kernel/build/user'
    build.mkdir(parents=True)
    shutil.copyfile(ROOT/'kernel/build/user/ext2.img', build/'ext2.img')
    fd = out/'kernel/kernel/fd_table.tkb'
    fd.write_text(instrument(fd.read_text(), args.retain))
    driver = out/'kernel/init/test_driver.tkb'
    driver.write_text(replace_once(driver.read_text(), '    if (kernel_test_init_script) {', '    if (kernel_test_init_script) {\n    retention_report("launch");'))
    space = out/'kernel/init/pool_space.tkb'
    space.write_text(replace_once(space.read_text(), '    kernel_boot_log("pool space: end=");', '    retention_report(phase);\n    kernel_boot_log("pool space: end=");'))
    platform = args.platform
    sources = [f'kernel/platform/{platform}/uart.tkb', 'kernel/platform/rpi5/pcie.tkb']
    if platform == 'qemu':
        sources += ['kernel/platform/rpi5/usb_xhci.tkb']
    sources += [f'kernel/platform/{platform}/mmu_layout.tkb', 'kernel/boot/fdt.tkb']
    if platform == 'qemu':
        sources += ['kernel/platform/qemu/memory.tkb']
    sources += ['kernel/drivers/net/'+('virtio_net' if platform == 'qemu' else 'rp1_gem')+'.tkb', 'kernel/drivers/block/virtio_blk.tkb', f'kernel/platform/{platform}/init.tkb']
    subprocess.run([str(ROOT/'_build/default/bin/main.exe'), *sources, '--target', 'aarch64-none-elf', '--cpu', 'cortex-a53' if platform == 'qemu' else 'cortex-a76', '--regions', '--forbid-trap', '--frame-pointers', '-g', '-o', str(out/'main.o')], cwd=out, check=True)
    objects = [ROOT/f'kernel/build/{platform}/{name}.o' for name in ('entry', 'user_entry', 'fpsimd_probe', 'pmu')]
    subprocess.run(['ld.lld-19', '-T', str(ROOT/('kernel/arch/arm64/boot/link_qemu.ld' if platform == 'qemu' else 'kernel/arch/arm64/boot/link.ld')), *map(str, objects), str(out/'main.o'), '-o', str(out/'kernel.elf')], check=True)
    subprocess.run(['python3', str(ROOT/'scripts/buildcheck_kernel_asm_invariants.py'), str(out/'kernel.elf'), '1' if platform == 'qemu' else '2'], check=True)
    subprocess.run(['python3', str(ROOT/'scripts/buildcheck_elf_symbol_alignment.py'), str(out/'kernel.elf'), 'boot_page_pool_cell', '16'], check=True)


if __name__ == '__main__':
    main()
