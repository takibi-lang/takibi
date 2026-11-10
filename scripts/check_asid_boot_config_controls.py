#!/usr/bin/env python3
"""Refuse weakened ASID source, caller, layout and linked-default premises."""

from copy import deepcopy
from unittest.mock import patch

import buildcheck_global_protection as protection
from buildcheck_allowed_callers import read_list
from buildcheck_asid_boot_config import image_problems, section_records, symbol_records
from check_asid_boot_config import ASID, BOOT, CALLERS, ENTRIES, PATH, read_sources, source_problems
from control_patch import replace_in_function, replace_once
from pass_line import CaseCount, report_pass

CASES = CaseCount()


def expect(ok, label):
    CASES.note()
    assert ok, label


def main():
    sources = read_sources()
    expect(not source_problems(sources), 'maintained source')
    rows = {
        'asid_boot_writer_mint': (PATH, [], 'AsidInitWriter', 'mmu_off,unsafe'),
        'asid_boot_config_initialize': (PATH, ['writer: sink AsidInitWriter', 'bits: usize'], '-', 'mmu_off'),
        'asid_init': (ASID, [], '-', 'mmu_off,unsafe'),
        'asid_width_bits': (PATH, [], 'usize', '-'),
        'asid_highest_value': (PATH, [], 'usize', '-'),
        'kernel_mmu_init': (BOOT, [], '-', 'mmu_off'),
        'foreign': (PATH, [], '-', '-'),
    }
    table = [dict(file=file, name=name, params=params, returns=returns,
                  declared=declared, effects=[], callees=[], values=[])
             for name, (file, params, returns, declared) in rows.items()]
    for helper, callers in CALLERS.items():
        for file, name in callers:
            next(r for r in table if (r['file'], r['name']) == (file, name))['callees'].append(helper + '@-')
    structs = {'AsidBootWord': [('value', '0'), ('.size', '8'), ('.members', '1')]}
    rules = read_list()
    row = dict(file=PATH, name='asid_bits', visibility='private', qualifier='-',
               type='AsidBootWord', protection='none')

    def admits(texts=sources, graph=table, policy=rules, record=row, layout=structs):
        return protection.asid_initializer_admitted(
            record, 'missing/globals.tsv', sources=texts, table=graph, rules=policy, structs=layout)

    expect(admits(), 'all exact premises')
    expect(admits(record=dict(row, name='asid_last')), 'second real word')
    changes = [
        (PATH, replace_once(sources[PATH], 'struct no_copy AsidBootWord', 'struct AsidBootWord')),
        (PATH, replace_once(sources[PATH], 'private value: usize;', 'value: usize;')),
        (PATH, replace_once(sources[PATH], 'private linear view AsidInitWriter;', 'linear view AsidInitWriter;')),
        (PATH, replace_once(sources[PATH], 'writer: sink AsidInitWriter', 'writer: borrow AsidInitWriter')),
        (PATH, replace_once(sources[PATH], '= { 8 };', '= { 0 };')),
        (PATH, replace_once(sources[PATH], '= { 255 };', '= { 0 };')),
        (PATH, replace_once(sources[PATH], 'return asid_bits.value;', 'return 16;')),
        (PATH, sources[PATH] + '\nfn overwrite() { asid_bits.value = 16; }\n'),
        (PATH, sources[PATH] + '\nfn mint_again() -> AsidInitWriter { return view AsidInitWriter; }\n'),
        (PATH, sources[PATH] + '\nprivate let alias: *AsidBootWord = &asid_bits;\n'),
        (ASID, replace_in_function(sources[ASID], 'fn asid_init(',
                                  'let writer = asid_boot_writer_mint();',
                                  'let writer = asid_boot_writer_mint(); let extra = asid_boot_writer_mint();')),
        (ASID, replace_in_function(sources[ASID], 'fn asid_init(',
                                  'asid_boot_config_initialize(writer, mmu_asid_bits());',
                                  'asid_boot_config_initialize(writer, mmu_asid_bits()); asid_boot_config_initialize(writer, 8);')),
        (BOOT, replace_in_function(sources[BOOT], 'fn kernel_mmu_init(',
                                  'asid_init();', 'asid_init(); asid_init();')),
        (BOOT, replace_in_function(sources[BOOT], 'fn kernel_mmu_init(',
                                  'page_allocator_init();\n    asid_init();',
                                  'asid_init();\n    page_allocator_init();')),
    ]
    for path in ENTRIES:
        changes.extend([
            (path, replace_once(sources[path], 'bl      kernel_mmu_init\n',
                                'bl      kernel_mmu_init\n    bl      kernel_mmu_init\n')),
            (path, replace_once(sources[path], 'bl      kernel_mmu_init\n', '')),
        ])
    for path, source in changes:
        changed = {**sources, path: source}
        expect(bool(source_problems(changed)) and not admits(texts=changed), 'changed exact source: ' + path)
    expect(admits(texts={**sources, PATH: sources[PATH] + '\n// asid_bits.value = 0;\n'}), 'comments do not change code')
    for path in sources:
        expect(not admits(texts={k: v for k, v in sources.items() if k != path}), 'missing source: ' + path)
    for key, value in [('file', ASID), ('name', 'unrelated'), ('visibility', 'public'),
                       ('qualifier', 'scratch'), ('type', 'usize'), ('protection', 'atomic')]:
        expect(not admits(record=dict(row, **{key: value})), 'changed global premise: ' + key)
    for graph in ([], table[:-1] + [dict(table[-1], values=['asid_boot_writer_mint@-'])]):
        expect(not admits(graph=graph), 'empty or function-value graph')
    for helper in CALLERS:
        for field in ('callees', 'values'):
            graph = deepcopy(table)
            graph[-1][field].append(helper + '@-')
            expect(not admits(graph=graph), 'foreign ' + field + ': ' + helper)
        graph = deepcopy(table)
        for entry in graph:
            entry['callees'] = [call for call in entry['callees'] if call != helper + '@-']
        expect(not admits(graph=graph), 'missing real caller: ' + helper)
    for name in rows:
        if name not in ('foreign', 'kernel_mmu_init'):
            expect(not admits(graph=[r for r in table if r['name'] != name]), 'missing typed definition: ' + name)
    graph = deepcopy(table)
    next(r for r in graph if r['name'] == 'asid_boot_config_initialize')['params'][0] = 'writer: borrow AsidInitWriter'
    expect(not admits(graph=graph), 'compiled setter does not consume')
    graph = deepcopy(table)
    next(r for r in graph if r['name'] == 'asid_width_bits')['callees'] = ['lock@-']
    expect(not admits(graph=graph), 'getter no longer a plain load')
    expect(not admits(policy=[]), 'missing caller policy')
    expect(not admits(layout={}), 'missing compiled layout')
    expect(not admits(layout={'AsidBootWord': [('value', '8'), ('.size', '16'), ('.members', '2')]}), 'changed compiled layout')
    expect(not protection.asid_initializer_admitted(row, 'missing/globals.tsv'), 'missing actual facts')

    header = '# takibi globals, format 3\n' + '\t'.join(protection.COLUMNS) + '\n'
    raw = header + '\t'.join(dict(row, line='1', protection='asid_initializer')[k]
                             for k in protection.COLUMNS) + '\n'
    try:
        protection.parse_table(raw, 'forged')
    except protection.TableError:
        expect(True, 'raw derived class is refused')
    else:
        expect(False, 'raw derived class is refused')
    raw = header + '\t'.join(dict(row, line='1')[k] for k in protection.COLUMNS) + '\n'
    for origins in (('good', 'missing'), ('missing', 'good')):
        with patch.object(protection, 'asid_initializer_admitted', side_effect=lambda r, origin: origin == 'good'):
            found = protection.globals_of([(origin, raw) for origin in origins], debugger_set=set())
        expect(found[(PATH, 'asid_bits')]['protection'] == 'none', 'every platform supplies premises')

    data = bytearray(80)
    data[:7] = b'\x7fELF\x02\x01\x01'
    data[18:20] = (183).to_bytes(2, 'little')
    data[64:72] = (8).to_bytes(8, 'little')
    data[72:80] = (255).to_bytes(8, 'little')
    symbol_text = '''
    1: 0000000000001000 8 OBJECT GLOBAL DEFAULT 1 asid_bits
    2: 0000000000001008 8 OBJECT GLOBAL DEFAULT 1 asid_last
'''
    symbols = symbol_records(symbol_text)
    sections = section_records('  [ 1] .data PROGBITS 0000000000001000 000040 000010 00 WA 0 0 8\n')
    expect(not image_problems(data, symbols, sections, structs), 'linked byte/layout parser')
    image_cases = [
        (b'', symbols, sections, structs),
        (data, symbols[:1], sections, structs),
        (data, symbols + symbols[:1], sections, structs),
        (data, [dict(symbols[0], size=16), symbols[1]], sections, structs),
        (data, [dict(symbols[0], kind='FUNC'), symbols[1]], sections, structs),
        (data, [dict(symbols[0], address=0x1001), symbols[1]], sections, structs),
        (data, symbols, {'1': ('NOBITS', 0x1000, 64, 16)}, structs),
        (data, symbols, {}, structs),
        (data, [dict(symbols[0], address=0x2000), symbols[1]], sections, structs),
        (data[:64] + bytes(16), symbols, sections, structs),
        (data, [symbols[0], dict(symbols[1], address=0x1000)], sections, structs),
        (data, symbols, sections, {}),
    ]
    for args in image_cases:
        expect(bool(image_problems(*args)), 'missing or changed linked image premise')
    report_pass('asid-boot-config controls',
                'exact source, mint/caller nonvacuity, type/layout and linked defaults fail closed',
                cases=CASES.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
