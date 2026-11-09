#!/usr/bin/env python3
"""Faithful controls for the block queue's closed setup mint and CPU guard boundary."""
import sys
import check_virtio_queue_mints as policy
from pass_line import CaseCount, report_pass
from control_patch import replace_once

CASES = CaseCount()
BASE = policy.DECL+'\n'+policy.HEADER+policy.BODY+'''
fn virtio_blk_init(guard: borrow BlockDeviceGuard[&block_device_lock]) -> bool {
    return virtio_blk_setup_queue(guard);
}
fn write(guard: borrow BlockDeviceGuard[&block_device_lock]) {
    guarded_ref(guard, virtio_blk_queue.queue).desc[0].len = 1;
}
'''


def main():
    failures=[]
    def case(label,text,accept,path=policy.DRIVER,extra=None):
        CASES.note()
        files={path:text}
        if extra: files.update(extra)
        errors,accesses=policy.problems_in(files)
        if bool(errors)==accept or (accept and not accesses):
            failures.append(label+': '+repr(errors))
    CASES.note()
    errors,accesses=policy.problems_in(policy.source_files())
    if errors or not accesses: failures.append('real maintained tree: '+repr(errors))
    case('closed setup and guarded CPU writes',BASE,True)
    case('arbitrary whitespace and comments',BASE.replace('(', '\n(\n').replace(';','; /* comment */\n'),True)
    case('literal decoy',BASE+'fn text() { emit("virtio_blk_queue VirtioBlkQueueStorage"); }',True)
    case('comment decoy',BASE+'// &virtio_blk_queue as usize\n',True)
    snippets={
        'pointer alias':'let p = &virtio_blk_queue;',
        'mutable aggregate copy':'let mut copy: VirtioBlkQueueStorage = virtio_blk_queue;',
        'global copy':'',
        'direct field read':'let n = virtio_blk_queue.queue.avail.idx;',
        'guarded pointer escape':'let p = &guarded_ref(guard, virtio_blk_queue.queue).desc;',
        'container cast':'let n:usize = &virtio_blk_queue as usize;',
        'container argument':'consume(virtio_blk_queue);',
        'storage shadow':'let virtio_blk_queue:usize = 0;',
        'wrapper shadow':'let VirtioBlkQueueStorage:usize = 0;',
    }
    # Address-of guarded_ref is already compiler-rejected; the source check
    # also keeps the broader container policy from being mistaken for a mint.
    # It accepts guarded_ref as a place; compiler tests own its escape rule.
    snippets.pop('guarded pointer escape')
    snippets.pop('global copy')
    for label,snippet in snippets.items():
        case(label,BASE+'fn escape() !{unsafe} { '+snippet+' }',False)
    case('global initializer copy',BASE+'let mut copy: VirtioBlkQueueStorage = virtio_blk_queue;',False)
    case('foreign wrapper use',BASE,False,extra={'kernel/foreign.tkb':'fn f() { let p = &virtio_blk_queue; }'})
    case('forged file',BASE,False,path='kernel/other.tkb')
    case('forged setup name',BASE.replace('fn virtio_blk_setup_queue','fn other_setup'),False)
    case('wrong guard identity',BASE.replace('guard: borrow BlockDeviceGuard[&block_device_lock]','guard: borrow BlockDeviceGuard[&other_lock]'),False)
    case('owned guard',BASE.replace('guard: borrow BlockDeviceGuard','guard: BlockDeviceGuard'),False)
    case('guard shadow',BASE.replace('    guarded_ref(guard,','    let guard = other;\n    guarded_ref(guard,'),False)
    case('guard arm shadow',BASE.replace('    guarded_ref(guard,',
         '    match incoming { V::Held(guard) => { guarded_ref(guard,').replace(
         '.desc[0].len = 1;', '.desc[0].len = 1; release(guard); } }'),False)
    case('wrapper aggregate embedding',BASE+'struct Box { value: VirtioBlkQueueStorage; }',False)
    case('guarded reference still compiler-owned',BASE.replace(
         'guarded_ref(guard, virtio_blk_queue.queue).desc[0].len = 1;',
         'let p = &guarded_ref(guard, virtio_blk_queue.queue).desc;'),True)
    case('guard loop shadow',BASE.replace('    guarded_ref(guard,','    for guard:usize in 0..<1 {}\n    guarded_ref(guard,'),False)
    case('nested capture',BASE.replace('    guarded_ref(guard,','    let callback = fn() { guarded_ref(guard,').replace('.desc[0].len = 1;','.desc[0].len = 1; };'),False)
    case('wrong caller',BASE.replace('fn virtio_blk_init','fn other_init'),False)
    case('setup function value',BASE+'fn escape() { let callback = virtio_blk_setup_queue; }',False)
    case('wrong call argument',BASE.replace('return virtio_blk_setup_queue(guard);','return virtio_blk_setup_queue(other);'),False)
    case('wrapper altered layout',BASE.replace('private queue: VirtioBlkQueue','padding:usize; private queue: VirtioBlkQueue'),False)
    case('alignment weakened',BASE.replace('align(64)','align(8)'),False)
    case('duplicate storage',BASE+policy.DECL,False)
    case('duplicate setup',BASE+policy.HEADER+policy.BODY,False)
    for label,snippet in {
        'integer global escape':'saved = desc;',
        'integer call escape':'consume(desc);',
        'integer return':'return desc;',
        'integer alias':'let hidden:usize = desc + 0;',
        'integer closure capture':'let callback = fn() { consume(desc); };',
        'guard release before sinks':'block_device_give(guard);',
        'address local shadow':'let desc:usize = 0;',
        'guard shadow in setup':'let guard = other;',
        'new pointer alias':'let p = &virtio_blk_queue;',
    }.items():
        case(label,replace_once(BASE, 'virtio_blk_regs.queue_desc_low',
                                    snippet+'\n    virtio_blk_regs.queue_desc_low'),False)
    case('wrong MMIO sink',BASE.replace('queue_driver_low','queue_device_low'),False)
    case('wrong low/high bits',BASE.replace('(desc >> 32)','(desc >> 16)'),False)
    case('address initializer altered',BASE.replace('offsetof(VirtioBlkQueue, avail);','offsetof(VirtioBlkQueue, desc);'),False)
    case('missing guard accessor',BASE.replace('guarded_ref(guard, virtio_blk_queue.queue)','virtio_blk_queue.queue'),False)
    case('no reviewed storage',BASE.replace(policy.DECL,''),False)
    case('no real accesses',policy.DECL+'\n'+policy.HEADER+policy.BODY,False)
    for failure in failures: print('FAIL virtio-queue-mints-controls: '+failure)
    if failures: return 1
    report_pass('virtio-queue-mints-controls','real driver and copy/address/integer/guard/caller/provenance/layout controls retain the bounded mint',cases=CASES.ran)
    return 0


if __name__=='__main__': sys.exit(main())
