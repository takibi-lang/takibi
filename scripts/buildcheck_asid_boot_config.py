#!/usr/bin/env python3
"""Check the real ASID initializer API and linked debugger-visible defaults.

api <takibi> compiles separate-file positive and authority-bypass controls.
image <elf> <structs.tsv> checks actual symbols, payload layout and 8/255
file-backed defaults in each normal/debug platform image. Neither mode runs
a guest. The exact source/caller admission is a separate build boundary.
"""

from pathlib import Path
import re
import subprocess
import sys
import tempfile

from check_asid_boot_config import PATH, WORDS, layout_problems
from pass_line import report_pass
from struct_layout_gdb import read_structs

ROOT = Path(__file__).resolve().parent.parent


def symbol_records(text):
    records = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 8 and fields[0].endswith(':') and fields[-1] in WORDS:
            records.append(dict(name=fields[7], address=int(fields[1], 16),
                                size=int(fields[2]), kind=fields[3],
                                binding=fields[4], visibility=fields[5], section=fields[6]))
    return records


def section_records(text):
    pattern = re.compile(r'^\s*\[\s*(\d+)\]\s+\S+\s+(\S+)\s+'
                         r'([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+', re.M)
    return {index: (kind, int(address, 16), int(offset, 16), int(size, 16))
            for index, kind, address, offset, size in pattern.findall(text)}


def image_problems(data, symbols, sections, structs):
    found = list(layout_problems(structs))
    if (len(data) < 64 or data[:7] != b'\x7fELF\x02\x01\x01'
            or int.from_bytes(data[18:20], 'little') != 183):
        found.append('expected an AArch64 little-endian ELF64 image')
    addresses = []
    for name, default in zip(WORDS, (8, 255)):
        matches = [s for s in symbols if s['name'] == name]
        if len(matches) != 1:
            found.append(f'{name}: expected exactly one defined eight-byte symbol')
            continue
        symbol = matches[0]
        if (symbol['kind'], symbol['binding'], symbol['visibility'], symbol['size']) != (
                'OBJECT', 'GLOBAL', 'DEFAULT', 8) or symbol['address'] % 8:
            found.append(f'{name}: retain the aligned global eight-byte object symbol')
            continue
        section = sections.get(symbol['section'])
        if section is None or section[0] != 'PROGBITS':
            found.append(f'{name}: initial value must remain file-backed data, not BSS')
            continue
        _, address, offset, size = section
        relative = symbol['address'] - address
        at = offset + relative
        if relative < 0 or relative + 8 > size or at < 0 or at + 8 > len(data):
            found.append(f'{name}: symbol payload is outside its file-backed section')
            continue
        if int.from_bytes(data[at:at + 8], 'little') != default:
            found.append(f'{name}: linked payload must initially contain {default}')
        addresses.append(symbol['address'])
    if len(addresses) == 2 and addresses[0] == addresses[1]:
        found.append('ASID configuration words must remain separate storage')
    return tuple(found)


def image(elf, facts):
    structs = read_structs(facts)
    symbols = symbol_records(subprocess.check_output(
        ['llvm-readelf-19', '--symbols', '--wide', str(elf)], text=True))
    sections = section_records(subprocess.check_output(
        ['llvm-readelf-19', '--sections', '--wide', str(elf)], text=True))
    found = image_problems(elf.read_bytes(), symbols, sections, structs)
    if found:
        raise ValueError('; '.join(found))
    report_pass('asid-boot-config image',
                'linked asid_bits/asid_last retain offset-zero eight-byte 8/255 data for debugger seeds',
                words=len(symbols))


POSITIVE = '''
fn hardware_width() -> usize {
    let field: usize = (mrs_id_aa64mmfr0_el1() >> 4) & 0xF;
    if (field == 2) { return 16; }
    return 8;
}
fn plain_consumer() -> usize { return asid_highest_value(); }
fn main() !{mmu_off, unsafe} {
    let before: usize = asid_width_bits();
    let before_limit: usize = asid_highest_value();
    let writer = asid_boot_writer_mint();
    asid_boot_config_initialize(writer, hardware_width());
    let after: usize = asid_width_bits();
    let after_limit: usize = asid_highest_value();
}
'''
NEGATIVE = (
    ('private-global', 'fn main() { asid_bits.value = 16; }', 'is a private global'),
    ('private-field', 'fn main() { let mut cell: AsidBootWord; cell.value = 16; }',
     "field 'AsidBootWord.value' is private"),
    ('whole-copy', 'fn main() { let mut cell: AsidBootWord; let mut copy: AsidBootWord = cell; }',
     'cannot be copied by value'),
    ('whole-replace', 'fn main() { let mut cell: AsidBootWord; let mut other: AsidBootWord; cell = other; }',
     'cannot be assigned as a whole'),
    ('forged-view', 'fn main() { let writer = view AsidInitWriter; asid_boot_config_initialize(writer, 16); }',
     "cannot mint private view 'AsidInitWriter'"),
    ('default-view', 'fn main() { let mut writer: AsidInitWriter; asid_boot_config_initialize(writer, 16); }',
     "cannot default-construct private ownership-bearing type 'AsidInitWriter'"),
    ('reused-view', 'fn main() !{mmu_off, unsafe} { let writer = asid_boot_writer_mint(); '
     'asid_boot_config_initialize(writer, 16); asid_boot_config_initialize(writer, 8); }',
     "linear value 'writer' was already consumed"),
    ('global-view', 'let mut escaped: AsidInitWriter; fn main() {}',
     'cannot hold an erased view'),
    ('address-view', 'fn main() !{mmu_off, unsafe} { let writer = asid_boot_writer_mint(); '
     'let address = &writer; asid_boot_config_initialize(writer, 16); }',
     'cannot take the address of erased view'),
    ('cast-view', 'fn main() !{mmu_off, unsafe} { let writer = asid_boot_writer_mint(); '
     'let value: usize = writer as usize; asid_boot_config_initialize(writer, 16); }',
     'cannot cast erased view'),
)


def api(compiler):
    accepted, rejected = 0, 0
    with tempfile.TemporaryDirectory(prefix='takibi-asid-api-') as temporary:
        work = Path(temporary)
        for name, body, diagnostic in (('valid', POSITIVE, ''), *NEGATIVE):
            source = work / (name + '.tkb')
            source.write_text(f'use "{ROOT / PATH}";\n' + body + '\n', encoding='ascii')
            result = subprocess.run(
                [str(compiler.resolve()), str(source), '--target', 'aarch64-none-elf',
                 '--cpu', 'cortex-a53', '--internal-allow-unused', '-o', str(work / (name + '.o'))],
                capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            if not diagnostic:
                if result.returncode != 0:
                    raise ValueError(f'{name}: valid real API rejected: {output}')
                accepted += 1
            else:
                if result.returncode == 0:
                    raise ValueError(f'{name}: invalid real API accepted')
                if diagnostic not in output:
                    raise ValueError(f'{name}: expected {diagnostic!r}, received {output}')
                rejected += 1
    report_pass('asid-boot-config API',
                'real MMU-off initialization/plain reads compile; consumer mutation and forged/reused/escaping authority fail',
                accepted=accepted, rejected=rejected)


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == 'api':
            api(Path(argv[2]))
        elif len(argv) == 4 and argv[1] == 'image':
            image(Path(argv[2]), Path(argv[3]))
        else:
            raise ValueError('usage: buildcheck_asid_boot_config.py api <takibi> | image <elf> <structs.tsv>')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('FAIL asid-boot-config: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
