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


NET_BASE = policy.NET_DECL+'\n'+policy.NET_HEADER+policy.NET_BODY+"""
fn net_init() {
    let guard = block_device_take_unaccounted();
    virtio_queue_setup(guard, 0, VIRTIO_USED_NET_RX);
    virtio_queue_setup(guard, 1, VIRTIO_USED_NET_TX);
    block_device_give(guard);
}
fn touch(guard: borrow BlockDeviceGuard[&block_device_lock], queue: {0..<2 as usize}) {
    guarded_ref(guard, virtio_net_queues.queues)[queue].desc[0].len = 1;
}
"""+'fn net_rx_acquire(ready: sink NetRxCanAcquire[net]) -> NetRxAcquire[net] '+policy.NET_RX_BODY+"\n"+\
'private fn virtio_net_rx_refill(r: borrow mut NetRxCanAcquire[net]) '+policy.NET_REFILL_BODY+"\n"+\
'fn virtio_net_tx_ring(r: borrow mut NetRxCanAcquire[net], address:usize, length:usize) '+policy.NET_TX_BODY


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
    def net_case(label,text,accept,path=policy.NET_DRIVER,extra=None):
        CASES.note()
        files={path:text}
        if extra: files.update(extra)
        errors,accesses=policy.problems_in(files,net=True)
        if bool(errors)==accept or (accept and not accesses):
            failures.append('net '+label+': '+repr(errors))
    CASES.note()
    errors,accesses=policy.problems_in(policy.source_files(),net=True)
    if errors or not accesses: failures.append('real net driver: '+repr(errors))
    net_case('closed boundary',NET_BASE,True)
    net_case('relayout',NET_BASE.replace('(', '\n(\n').replace(';','; /* layout */\n'),True)
    net_case('comment/literal',NET_BASE+'// &virtio_net_queues\nfn text(){ emit("VirtioNetQueueStorage"); }',True)
    for label,snippet in {
        'pointer':'let p = &virtio_net_queues;',
        'copy':'let mut copy:VirtioNetQueueStorage = virtio_net_queues;',
        'cast':'let n:usize = &virtio_net_queues as usize;',
        'argument':'consume(virtio_net_queues);',
        'wrapper embedding':'let mut other:VirtioNetQueueStorage;',
        'container shadow':'let virtio_net_queues:usize = 0;',
        'direct read':'let n = virtio_net_queues.queues[0].avail.idx;',
    }.items():
        net_case(label,NET_BASE+'fn escape() !{unsafe} { '+snippet+' }',False)
    net_case('forged file',NET_BASE,False,path='kernel/forged.tkb')
    net_case('forged name',NET_BASE.replace('fn virtio_queue_setup','fn impostor_setup'),False)
    net_case('foreign pointer',NET_BASE,False,extra={'kernel/other.tkb':'fn f(){ let p = &virtio_net_queues; }'})
    net_case('wrong guard',NET_BASE.replace('&block_device_lock','&other_lock'),False)
    net_case('owned guard',NET_BASE.replace('guard: borrow BlockDeviceGuard','guard: BlockDeviceGuard'),False)
    net_case('wrong stride',NET_BASE.replace('queue * sizeof(VirtqNetQueue)','queue * 128'),False)
    net_case('wrong alignment',NET_BASE.replace('align(64)','align(8)'),False)
    net_case('queue outside domain',NET_BASE.replace('queue: {0..<2 as usize}','queue:usize'),False)
    net_case('wrong caller',NET_BASE.replace('fn net_init()','fn other_init()'),False)
    net_case('function value',NET_BASE+'fn f(){ let setup = virtio_queue_setup; }',False)
    net_case('fake guard mint',NET_BASE.replace('let guard = block_device_take_unaccounted();','let guard = fake_guard();'),False)
    net_case('guard shadow',NET_BASE.replace('    guarded_ref(guard,','    let guard = other; guarded_ref(guard,'),False)
    for label,statement in {
        'integer global':'saved = desc;',
        'integer alias':'let hidden:usize = desc + 0;',
        'integer call':'consume(desc);',
        'integer return':'return desc;',
        'integer capture':'let cb = fn(){ consume(desc); };',
        'after release':'block_device_give(guard);',
    }.items():
        net_case(label,replace_once(NET_BASE,'virtio_net_regs.queue_desc_low',statement+' virtio_net_regs.queue_desc_low'),False)
    net_case('wrong sink',NET_BASE.replace('queue_driver_high','queue_device_high'),False)
    for label,old,new in (
            ('plain address store', 'atomic_word_store(&virtio_net_used_addr[queue], used);',
             'virtio_net_used_addr[queue] = used;'),
            ('wrong address slot', '&virtio_net_used_addr[queue]', '&virtio_net_used_addr[used_queue]'),
            ('missing address publication', 'atomic_word_store(&virtio_net_used_addr[queue], used);', ''),
            ('address publication reordered',
             'virtio_net_regs.queue_ready = 1;\n    atomic_word_store(&virtio_net_used_addr[queue], used);',
             'atomic_word_store(&virtio_net_used_addr[queue], used);\n    virtio_net_regs.queue_ready = 1;')):
        net_case(label,replace_once(NET_BASE,old,new),False)

    net_case('clear before try',NET_BASE.replace('    let guard = match block_device_try_take()',
             '    atomic_word_store(&virtio_rx_irq_flag, 0); let guard = match block_device_try_take()'),False)
    net_case('refill before try',NET_BASE.replace('    let guard = match block_device_try_take()',
             '    virtio_net_rx_refill(ready); let guard = match block_device_try_take()'),False)
    net_case('Busy flag loss',NET_BASE.replace('return NetRxAcquire::None(ready);',
             'atomic_word_store(&virtio_rx_irq_flag, 0); return NetRxAcquire::None(ready);'),False)
    net_case('Busy mutation',NET_BASE.replace('return NetRxAcquire::None(ready);',
             'virtio_pkt_free_index(); return NetRxAcquire::None(ready);'),False)
    net_case('blocking RX',NET_BASE.replace('let guard = match block_device_try_take()',
             'let guard = match blocking_try()'),False)
    net_case('wait while held',NET_BASE.replace('    virtio_notify(1);','    net_rx_wait(); virtio_notify(1);'),False)
    net_case('early release',NET_BASE.replace('    desc_set(guard,','    block_device_give(guard); desc_set(guard,'),False)
    for failure in failures: print('FAIL virtio-queue-mints-controls: '+failure)
    if failures: return 1
    report_pass('virtio-queue-mints-controls','real driver and copy/address/integer/guard/caller/provenance/layout controls retain the bounded mint',cases=CASES.ran)
    return 0


if __name__=='__main__': sys.exit(main())
