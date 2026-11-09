#!/usr/bin/env python3
"""Planted constructor bypasses for the RootHeld entry snapshot boundary."""

from pathlib import Path
from check_root_held_entries import CANONICAL, IMAGE, PROCESS, problems
from control_patch import replace_once, replace_in_function
from pass_line import report_pass


def main():
    sources = {str(path): path.read_text() for path in Path('kernel').rglob('*.tkb')
               if 'build' not in path.parts}
    assert not problems(sources)
    assert problems({**sources, PROCESS: replace_once(
        sources[PROCESS], 'private fn scheduled_process_running_state(',
        'fn scheduled_process_running_state(')})
    caller_text = Path('scripts/allowed_callers.tsv').read_text()
    owned = next(line for line in caller_text.splitlines(True)
                 if line.startswith('root-held-owned\t'))
    slot = next(line for line in caller_text.splitlines(True)
                if line.startswith('root-held-fixture-scheduled_process_probe_root_slot\t'))
    release = next(line for line in caller_text.splitlines(True)
                   if line.startswith('root-held-fixture-scheduled_process_probe_slot_release\t'))
    caller_mutations = [
        replace_once(caller_text, owned, ''),
        replace_once(caller_text, slot, replace_once(slot, '\t#1472\t', ',kernel/kernel/process.tkb:unreviewed\t#1472\t')),
        replace_once(caller_text, release, replace_once(release, '\t#1472\t', ',kernel/mm/address_space.tkb:process_address_space_probe\t#1472\t')),
    ]
    for changed in caller_mutations:
        assert problems(sources, changed)
    fields = slot.split('\t')
    fields[2] = ','.join(reversed(fields[2].split(',')))
    assert not problems(sources, replace_once(caller_text, slot, '\t'.join(fields)))
    original = sources[CANONICAL]
    mutations = [
        replace_once(original, 'private affine view RootHeld', 'affine view RootHeld'),
        replace_once(original, 'address_space_prepare_held(held, kernel_process_current_root(current))', 'address_space_prepare_held(held, address_space_root_of_key(7))'),
        original + '\nfn forged() { let bad = view RootHeld[0]; }\n',
        original + '\nlet mut bad: RootHeld[0];\n',
        original + '\nfn escaped() -> RootHeld[0] { return root_held_boot(); }\n',
        original + '\nfn changed() { held.target = address_space_root_of_key(7); }\n',
    ]
    expected = 'return address_space_prepare_held(held, scheduled_process_address_space_root_owned(owner));'
    mutations.extend([
        replace_once(original, expected,
                     'address_space_prepare_held(held, address_space_boot_root()); ' + expected),
        replace_once(original, expected,
                     'let alias = address_space_boot_root(); ' + expected),
        replace_once(original, expected,
                     'let mut target: AddressSpaceRoot = address_space_boot_root(); ' + expected),
    ])
    for changed in mutations:
        assert problems({**sources, CANONICAL: changed})
    assert problems({**sources, 'kernel/root_held_control.tkb':
                     'fn forged() { let mut bad: RootHeld[0]; }'})
    assert not problems({**sources, 'kernel/root_held_control.tkb':
                         '// RootHeld[0] is prose, not a constructor.\n'})
    image = sources[IMAGE]
    image_mutations = [
        replace_in_function(image, 'fn process_image_map_current(', 'image, target, mapped, entry, stack_pointer,',
                     'image, address_space_boot_root(), mapped, entry, stack_pointer,'),
        replace_in_function(image, 'fn process_image_unmap(', 'let mut target: AddressSpaceRoot = pages.root;',
                     'let mut target: AddressSpaceRoot = address_space_boot_root();'),
        replace_in_function(image, 'fn process_image_map_ext2_in_root(', 'process_image_map_current(slot, target, plan, argv, argc)',
                     'process_image_map_current(slot, address_space_boot_root(), plan, argv, argc)'),
        replace_in_function(image, 'fn process_image_map_ext2_in_root(', 'process_image_map_current(slot, target, plan, argv, argc)',
                     'process_image_map_current(slot, address_space_boot_root(), plan, argv, argc); process_image_map_current(slot, target, plan, argv, argc)'),
    ]
    reader = 'let mut target: AddressSpaceRoot = pages.root;'
    image_mutations.extend([
        replace_in_function(image, 'fn process_image_unmap(', reader,
                            reader + ' let mut target: AddressSpaceRoot = address_space_boot_root();'),
        replace_in_function(image, 'fn process_image_unmap(', reader,
                            reader + ' target = address_space_boot_root();'),
    ])
    for changed in image_mutations:
        assert problems({**sources, IMAGE: changed})
    report_pass('root-held-entries controls',
                'production and prose pass; constructor/storage/escape and extra-call/alias/rebinding bypasses fail',
                controls=len(mutations) + len(image_mutations) + len(caller_mutations) + 2)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
