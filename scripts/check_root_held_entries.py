#!/usr/bin/env python3
"""Close the physical RootHeld view constructors, not a lifetime proof.

The public entries re-borrow real current/reserved state at commit. Exact
compiled-call rows separately close their private adapters and the MMU leaf.
This source check prevents a new same-file constructor bypassing those rows and fixes every lower
call in the eight small adapters to its actual authority;
it does not prove arbitrary control flow or the trusted owner/root mapping.
"""

from pathlib import Path
import re

from check_process_running_mints import functions
from pass_line import report_pass
from source_scan import code_skeleton, per_file

CANONICAL = 'kernel/mm/address_space.tkb'
IMAGE = 'kernel/mm/process_image.tkb'
PROCESS = 'kernel/kernel/process.tkb'
MINTS = {'root_held_boot': 'returnviewRootHeld[0];',
         'root_held_current': 'returnviewRootHeld[source];',
         'root_held_owned': 'returnviewRootHeld[source];'}
ADAPTERS = {
    'address_space_prepare_activation':
        'address_space_prepare_held(held,scheduled_process_address_space_root_owned(owner))',
    'address_space_commit_activation':
        'address_space_commit_held(held,scheduled_process_address_space_root_owned(owner),prepared)',
    'address_space_prepare_current_activation':
        'address_space_prepare_held(held,kernel_process_current_root(current))',
    'address_space_commit_current_activation':
        'address_space_commit_held(held,kernel_process_current_root(current),prepared)',
    'address_space_prepare_boot_activation':
        'address_space_prepare_held(held,address_space_boot_root())',
    'address_space_commit_boot_activation':
        'address_space_commit_held(held,address_space_boot_root(),prepared)',
    'address_space_activate_boot_root':
        'address_space_activate_held(held,address_space_boot_root())',
    'address_space_activate_owned_root':
        'address_space_activate_held(held,scheduled_process_address_space_root_owned(owner))',
}
MINT = re.compile(r'\bview\s+RootHeld\s*\[')
BINDING = re.compile(r'\blet\s+(?:mut\s+)?\w+\s*:\s*RootHeld\s*\[')

# The prospective #981 contract stays explicit when activation switches to
# current authority: mapping/install/unmap still use the image's target.
IMAGE_ROOT_READERS = {
    'process_image_exec_install': 'process_image_root_checked(pages.root)',
    'process_image_unmap': 'letmuttarget:AddressSpaceRoot=pages.root;',
    'process_image_gap_is_unmapped': 'letmuttarget:AddressSpaceRoot=pages.root;',
}
IMAGE_CALLS = {
    'process_image_map_ext2_in_root': {'process_image_map_current': 'slot,target,'},
    'process_image_pair_map_ext2_in_root': {'process_image_pair_probe': 'slot,target,'},
    'process_image_map_current': {'process_image_map_segments': 'slot,target,',
                                  'process_image_install_page': 'target,'},
    'process_image_pair_probe': {'process_image_map_segments': 'slot,target,',
                                'process_image_install_page': 'target,'},
    'process_image_map_segments': {'process_image_install_page': 'target,'},
    'process_image_install_page': {'address_space_map_page': 'target,'},
    'process_image_unmap': {'process_image_unmap_pages': 'target,'},
    'process_image_gap_is_unmapped': {'process_image_pte_read': 'target,'},
}


@per_file
def image_problems(source):
    found = []
    raw_bodies = {name: body for name, _, body in functions(source)}
    bodies = {name: re.sub(r'\s+', '', body) for name, body in raw_bodies.items()}
    for name in set(IMAGE_CALLS) | set(IMAGE_ROOT_READERS):
        body = bodies.get(name, '')
        if not body:
            found.append(f'{name}: missing explicit image-target path')
        raw = raw_bodies.get(name, '')
        bindings = re.findall(r'\blet\s+(?:mut\s+)?target\b[^;]*;', raw)
        expected_bindings = ([IMAGE_ROOT_READERS[name]]
                             if name in ['process_image_unmap', 'process_image_gap_is_unmapped']
                             else [])
        if [re.sub(r'\s+', '', binding) for binding in bindings] != expected_bindings:
            found.append(f'{name}: no image-target shadowing or replacement binding')
        if ('kernel_process_current_root' in body or
                re.search(r'(?<![\w.])target\s*=(?!=)', raw)):
            found.append(f'{name}: image target must not be replaced by current/root context')
        if name in IMAGE_ROOT_READERS and IMAGE_ROOT_READERS[name] not in body:
            found.append(f'{name}: preserve ProcessImagePages.root')
        for callee, prefix in IMAGE_CALLS.get(name, {}).items():
            calls = body.count(callee + '(')
            matching = body.count(callee + '(' + prefix)
            if calls == 0 or calls != matching:
                found.append(f'{name}: every {callee} call must use the explicit image target')
    for name in ['process_image_map_current', 'process_image_pair_probe']:
        if not re.search(r'letmutpages:ProcessImagePages\[[^]]+\]=\{image,target,', bodies.get(name, '')):
            found.append(f'{name}: mapped pages must retain their actual target root')
    return tuple(found)


@per_file
def problems_in(path, source):
    code = code_skeleton(source)
    found = []
    if path == IMAGE:
        found.extend(image_problems(source))
    if path == PROCESS and not re.search(
            r'private\s+fn\s+scheduled_process_running_state\s*\(', code):
        found.append('Running reservation factory must remain private and compiled-caller confined')
    if path != CANONICAL:
        if re.search(r'\bRootHeld\b', code):
            found.append(f'{path}: RootHeld stays inside its entry module')
        return tuple(found)
    if not re.search(r'private\s+affine\s+view\s+RootHeld\[source:\s*usize\]', code):
        found.append('RootHeld must retain its private source-generation index')
    expected_bindings = 0
    mints = set()
    for name, header, body in functions(source):
        bindings = len(MINT.findall(body))
        if bindings:
            expected_bindings += bindings
            mints.add(name)
            if name not in MINTS or bindings != 1:
                found.append(f'{name}: unreviewed RootHeld constructor')
            elif MINTS[name] not in re.sub(r'\s+', '', body):
                found.append(f'{name}: source-generation mint changed')
        if name in ADAPTERS:
            factory = ('root_held_boot' if 'boot' in name
                       else 'root_held_current' if 'current' in name else 'root_held_owned')
            argument = ('' if factory == 'root_held_boot' else
                        'current' if factory == 'root_held_current' else 'owner')
            returns = 'return' if 'activate_' not in name else ''
            expected = ('{letheld=' + factory + '(' + argument + ');' +
                        returns + ADAPTERS[name] + ';}')
            if expected != re.sub(r'\s+', '', body):
                found.append(f'{name}: every root entry must use exactly its retaining authority; extra calls/aliases/rebinding require review')
        if re.search(r'->\s*RootHeld\b', header) and name not in MINTS:
            found.append(f'{name}: unreviewed RootHeld return')
    if mints != set(MINTS) or expected_bindings != 3 or len(MINT.findall(code)) != 4 or BINDING.search(code):
        found.append('exactly the boot, current and owned RootHeld constructors must exist')
    if set(ADAPTERS) - {name for name, _, _ in functions(source)}:
        found.append('missing RootHeld entry adapter')
    if re.search(r'\.\s*target\s*=(?!=)', code):
        found.append('prepared root targets must not be reassigned after construction')
    return tuple(found)


def problems(sources):
    found = []
    if CANONICAL not in sources:
        found.append('missing RootHeld entry module')
    if IMAGE not in sources:
        found.append('missing explicit image-target module')
    for path, source in sources.items():
        found.extend(problems_in(path, source))
    return found


def main():
    sources = {str(path): path.read_text() for path in Path('kernel').rglob('*.tkb')
               if 'build' not in path.parts}
    found = problems(sources)
    if found:
        for message in found:
            print('FAIL root-held-entries: ' + message)
        return 1
    report_pass('root-held-entries',
                'three erased mints/eight exact adapters retain authority; image maps and pages retain explicit target roots; compiled rows confine entries',
                constructors=sum(name in MINTS for name, _, _ in functions(sources[CANONICAL])))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
