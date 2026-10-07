#!/usr/bin/env python3
"""Mutation controls for the finite stopped RegionPool mint boundary."""
import pathlib
import tempfile

from check_stopped_pool_inspection import MINTS, ROOT, problems
from pass_line import CaseCount, report_pass


def main():
    cases = CaseCount()
    assert not problems(ROOT)
    paths = {key[0] for key in MINTS} | {'kernel/lib/occupancy.tkb'}
    mutations = []
    for function in ('world_stop_resume', 'cpu_start_reserve', 'cpu_start_gate_release'):
        for kind in MINTS.values():
            mutations.append(('kernel/lib/occupancy.tkb',
                f'fn {function}', f'changes_witness_RegionInspection__{kind}',
                f'changes_witness_removed_{kind}', 'missing invalidation'))
    mutations += [
        ('kernel/mm/address_space.tkb', 'private fn address_space_inspect_stopped',
         'stopped: borrow MachineStopped[&kernel_world_stop]',
         'stopped: MachineStopped[&kernel_world_stop]', 'must borrow'),
        ('kernel/mm/address_space.tkb', 'private fn address_space_inspect_stopped',
         'irq_masking_guard', 'unsafe', 'IRQ exclusion'),
        ('kernel/mm/address_space.tkb', 'private fn address_space_inspect_stopped',
         'private fn address_space_inspect_stopped',
         'fn address_space_inspect_stopped', 'private mint'),
    ]
    for file, start, old, new, diagnostic in mutations:
        cases.note()
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            for relative in paths:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text((ROOT / relative).read_text(encoding='ascii'), encoding='ascii')
            target = root / file
            source = target.read_text(encoding='ascii')
            position = source.index(start)
            tail = source[position:]
            assert old in tail
            target.write_text(source[:position] + tail.replace(old, new, 1), encoding='ascii')
            found = problems(root)
            assert any(diagnostic in item for item in found), (start, old, found)
    cases.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        for relative in paths:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((ROOT / relative).read_text(encoding='ascii'), encoding='ascii')
        target = root / 'kernel/mm/address_space.tkb'
        with target.open('a', encoding='ascii') as output:
            output.write('\nfn unchecked() { region_pool_inspect_unproven__AddressSpaceBacking(); }\n')
        assert any('unreviewed inspection mint' in item for item in problems(root))
    report_pass('stopped-pool-inspection-controls',
                'every resume/start marker, missing borrow/IRQ exclusion, public mint and unreviewed mint are refused',
                cases=cases.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
