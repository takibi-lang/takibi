#!/usr/bin/env python3
"""Keep unproven RegionPool inspection at four named stopped mint sites.

The compiler checks borrowed stop/pool identities and local witness lifetimes.
This source gate checks the finite mint set and completeness of physical
context annotations. It does not prove CPU holding or metadata correctness.
"""
import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
MINTS = {
    ('kernel/mm/process_image.tkb', 'process_image_inspect_stopped'): 'ProcessImageRecord',
    ('kernel/mm/address_space.tkb', 'address_space_inspect_stopped'): 'AddressSpaceBacking',
    ('kernel/kernel/fd_table.tkb', 'fd_context_inspect_stopped'): 'ProcessFdContext',
    ('kernel/kernel/fd_table.tkb', 'fd_block_inspect_stopped'): 'FdBlock',
}
FUNCTION = re.compile(r'^(?:private )?(?:inline |noinline )?fn (\w+)\(', re.M)
MINT = re.compile(r'\bregion_pool_inspect_unproven__(\w+)\b')


def functions(source):
    code = '\n'.join(line.split('//', 1)[0] for line in source.splitlines())
    starts = list(FUNCTION.finditer(code))
    return {match.group(1): code[match.start():starts[i + 1].start()
            if i + 1 < len(starts) else len(code)]
            for i, match in enumerate(starts)}


def problems(root):
    failures, found, references = [], set(), 0
    for path in sorted((root / 'kernel').rglob('*.tkb')):
        relative = str(path.relative_to(root))
        source = path.read_text(encoding='ascii')
        references += len(MINT.findall('\n'.join(line.split('//', 1)[0] for line in source.splitlines())))
        bodies = functions(source)
        for name, body in bodies.items():
            calls = MINT.findall(body)
            if not calls:
                continue
            key = relative, name
            found.add(key)
            if key not in MINTS or calls != [MINTS.get(key)]:
                failures.append(f'{relative}:{name}: unreviewed inspection mint {calls}')
                continue
            header = body.split('{', 1)[0]
            if not header.startswith('private fn ') or \
                    'stopped: borrow MachineStopped[&kernel_world_stop]' not in header or \
                    'irq_masking_guard' not in body.split('}', 1)[0] or \
                    f'&kernel_world_stop' not in body[body.find('return '):]:
                failures.append(f'{name}: private mint must borrow the production stop and retain IRQ exclusion')
    if references != len(found):
        failures.append('inspection references must be one call per declared function, with no global or duplicate use')
    for key in sorted(MINTS.keys() - found):
        failures.append(f'{key[1]}: declared inspection mint is missing')
    occupancy = functions((root / 'kernel/lib/occupancy.tkb').read_text(encoding='ascii'))
    for name in ('world_stop_resume', 'cpu_start_reserve', 'cpu_start_gate_release'):
        effect = re.search(r'!\{([^}]+)\}', occupancy.get(name, ''))
        header = effect.group(1) if effect else ''
        for kind in MINTS.values():
            if f'changes_witness_RegionInspection__{kind}' not in header:
                failures.append(f'{name}: missing invalidation for RegionInspection__{kind}')
    return failures


def main():
    failures = problems(ROOT)
    for failure in failures:
        print('FAIL stopped-pool-inspection: ' + failure, file=sys.stderr)
    if failures:
        return 1
    report_pass('stopped-pool-inspection',
                'four private mints borrow full machine authority; resume and participant changes invalidate every production inspection type',
                references=sum(len(MINT.findall('\n'.join(line.split('//', 1)[0] for line in path.read_text(encoding='ascii').splitlines())))
                               for path in (ROOT / 'kernel').rglob('*.tkb')))
    return 0


if __name__ == '__main__':
    sys.exit(main())
