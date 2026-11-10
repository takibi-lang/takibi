#!/usr/bin/env python3
"""Keep the two-word ASID initializer's small trusted boundary closed.

This is an exact adapter policy using the shared source scanner, not a
general initializer analysis. Existing private/no_copy/linear-view rules
protect consumers. Caller facts and linked image checks supply separate
evidence; the unsafe mint and assembly boot epoch remain trusted.
"""

from pathlib import Path
import re

from check_process_running_mints import functions
from pass_line import report_pass
from source_scan import code_skeleton, per_file

PATH = 'kernel/arch/arm64/mm/asid_boot_config.tkb'
ASID = 'kernel/arch/arm64/mm/asid.tkb'
BOOT = 'kernel/mm/address_space.tkb'
ENTRIES = ('kernel/arch/arm64/boot/entry.S',
           'kernel/arch/arm64/boot/entry_qemu.S')
WORDS = ('asid_bits', 'asid_last')
CALLERS = {
    'asid_boot_writer_mint': {(ASID, 'asid_init')},
    'asid_boot_config_initialize': {(ASID, 'asid_init')},
    'asid_init': {(BOOT, 'kernel_mmu_init')},
}

# The entire small library is closed: extra writers, exports, mints, aliases
# or changed defaults cannot inherit admission from its filename/type name.
API = '''
struct no_copy AsidBootWord { private value: usize; }
private linear view AsidInitWriter;
private let mut asid_bits: AsidBootWord = { 8 };
private let mut asid_last: AsidBootWord = { 255 };
fn asid_boot_writer_mint() -> AsidInitWriter !{mmu_off, unsafe} {
    return view AsidInitWriter;
}
fn asid_boot_config_initialize(writer: sink AsidInitWriter, bits: usize) !{mmu_off} {
    asid_bits.value = bits;
    asid_last.value = (1 << bits) - 1;
}
fn asid_width_bits() -> usize { return asid_bits.value; }
fn asid_highest_value() -> usize { return asid_last.value; }
'''
INITIALIZER = '''{
    let writer = asid_boot_writer_mint();
    asid_boot_config_initialize(writer, mmu_asid_bits());
    let mut state: AsidState = locked_cell_load_boot(&asid_cell);
    state.generation = 1;
    state.next = 1;
    locked_cell_store_boot(&asid_cell, state);
}'''
BOOT_BODY = '''{
    page_allocator_init();
    asid_init();
    match address_space_ensure_boot_root() {
        AddressSpaceEnsureResult::SlotOutOfRange => {}
        AddressSpaceEnsureResult::OutOfMemory => {}
        AddressSpaceEnsureResult::Ok => {}
    }
    kernel_mmu_activate(address_space_backing_root0.l1_physical,
                        address_space_backing_root0.asid);
}'''


def compact(source):
    return re.sub(r'\s+', '', code_skeleton(source))


@per_file
def problems(path, source):
    if path == PATH:
        return (() if compact(source) == compact(API) else
                ('ASID library must retain its exact private no_copy words, '
                 '8/255 defaults, erased writer and consuming initializer',))
    if path in ENTRIES:
        code = code_skeleton(source)
        init = list(re.finditer(r'^\s*bl\s+kernel_mmu_init\s*$', code, re.M))
        main = list(re.finditer(r'^\s*bl\s+main\s*$', code, re.M))
        return (() if len(init) == len(main) == 1 and init[0].start() < main[0].start()
                else ('primary assembly entry must initialize the MMU once before main',))
    name, expected, header = (
        ('asid_init', INITIALIZER, 'fnasid_init()!{mmu_off,unsafe}') if path == ASID
        else ('kernel_mmu_init', BOOT_BODY, 'fnkernel_mmu_init()!{mmu_off}'))
    bodies = [(h, b) for n, h, b in functions(source) if n == name]
    if len(bodies) != 1:
        return (f'{name}: expected one boot initializer',)
    h, body = bodies[0]
    if compact(h) != header or compact(body) != compact(expected):
        return (f'{name}: retain the exact single initializer and existing MMU-off order',)
    return ()


def read_sources(root=Path('.')):
    return {path: (root / path).read_text(encoding='ascii')
            for path in (PATH, ASID, BOOT, *ENTRIES)}


def source_problems(sources):
    return tuple(f'{path}: {message}'
                 for path in (PATH, ASID, BOOT, *ENTRIES)
                 for message in (problems(path, sources[path]) if path in sources
                                 else ('missing source premise',)))


def layout_problems(structs):
    expected = [('value', '0'), ('.size', '8'), ('.members', '1')]
    return (() if structs.get('AsidBootWord') == expected else
            ('AsidBootWord must have one offset-zero eight-byte field',))


def main():
    found = source_problems(read_sources())
    for message in found:
        print('FAIL asid-boot-config: ' + message)
    if found:
        return 1
    report_pass('asid-boot-config',
                'exact two-word API and single MMU-off initializer retain the boot boundary',
                words=2, mints=1)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
