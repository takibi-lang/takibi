#!/usr/bin/env python3
"""Bound virtio queue container addresses to reviewed setup MMIO programming.

Ordinary CPU access uses guarded_ref. The language still permits taking a
container's address; this repository policy closes that trusted mint to an
exact setup body, immutable address locals and low/high MMIO sinks. It is
not general integer noninterference, device ownership or quiescence proof.
"""
import sys
from pathlib import Path

from check_io_handle_boot_phase import TOKEN, scan
from pass_line import report_pass
from source_scan import code_skeleton, per_file

ROOT = Path(__file__).resolve().parent.parent
DRIVER = 'kernel/drivers/block/virtio_blk.tkb'
STORAGE = 'VirtioBlkQueueStorage'
GLOBAL = 'virtio_blk_queue'
SETUP = 'virtio_blk_setup_queue'
DECL = '''struct VirtioBlkQueueStorage {
    private queue: VirtioBlkQueue guarded_by(block_device_lock);
}
private let mut virtio_blk_queue: VirtioBlkQueueStorage align(64);'''
HEADER = '''private fn virtio_blk_setup_queue(
    guard: borrow BlockDeviceGuard[&block_device_lock]) -> bool !{unsafe}'''
# Deliberately closed: a new local, use, call, branch, capture or sink is a
# new trusted mint review, not an inferred integer-flow guarantee.
BODY = '''{
    virtio_blk_regs.queue_sel = 0;
    if (virtio_blk_regs.queue_num_max < VIRTIO_QNUM as u32) { return false; }
    virtio_blk_regs.queue_num = VIRTIO_QNUM as i32;
    let used: usize = virtio_used_go(VIRTIO_USED_BLK);
    if (used == 0) { return false; }
    static_assert(offsetof(VirtioBlkQueueStorage, queue) == 0,
                  "queue payload must retain its device address");
    static_assert(sizeof(VirtioBlkQueueStorage) == 256,
                  "queue storage must retain its fixed device extent");
    static_assert(sizeof(VirtioBlkQueue) == 256,
                  "queue layout must retain its fixed device extent");
    static_assert(offsetof(VirtioBlkQueue, desc) == 0,
                  "descriptor table must start at the queue base");
    static_assert(offsetof(VirtioBlkQueue, avail) == 128,
                  "avail ring must follow eight descriptors");
    let desc: usize = (&virtio_blk_queue as usize) + offsetof(VirtioBlkQueue, desc);
    let avail: usize = (&virtio_blk_queue as usize) + offsetof(VirtioBlkQueue, avail);
    virtio_blk_regs.queue_desc_low = (desc & 0xFFFFFFFF) as u32;
    virtio_blk_regs.queue_desc_high = (desc >> 32) as u32;
    virtio_blk_regs.queue_driver_low = (avail & 0xFFFFFFFF) as u32;
    virtio_blk_regs.queue_driver_high = (avail >> 32) as u32;
    virtio_blk_regs.queue_device_low = (used & 0xFFFFFFFF) as u32;
    virtio_blk_regs.queue_device_high = (used >> 32) as u32;
    virtio_blk_regs.queue_ready = 1;
    return true;
}'''
GUARD = 'guard: borrow BlockDeviceGuard[&block_device_lock]'
ACCESS = 'guarded_ref(guard, virtio_blk_queue.queue)'


NET_DRIVER = 'kernel/drivers/net/virtio_net.tkb'
NET_STORAGE = 'VirtioNetQueueStorage'
NET_GLOBAL = 'virtio_net_queues'
NET_SETUP = 'virtio_queue_setup'
NET_DECL = """struct VirtioNetQueueStorage {
    private queues: [VirtqNetQueue; 2] guarded_by(block_device_lock);
}
private let mut virtio_net_queues: VirtioNetQueueStorage align(64);"""
NET_HEADER = """private fn virtio_queue_setup(
    guard: borrow BlockDeviceGuard[&block_device_lock], queue: {0..<2 as usize}, used_queue: usize) -> bool !{unsafe}"""
NET_BODY = """{
    virtio_net_regs.queue_sel = queue as i32;
    if (virtio_net_regs.queue_num_max < QNUM as u32) { return false; }
    virtio_net_regs.queue_num = QNUM as i32;
    let used: usize = virtio_used_go(used_queue);
    if (used == 0) { return false; }
    static_assert(offsetof(VirtioNetQueueStorage, queues) == 0,
                  "queue array must retain its device address");
    static_assert(sizeof(VirtioNetQueueStorage) == 512,
                  "two queues must retain their fixed device extent");
    static_assert(sizeof(VirtqNetQueue) == 256,
                  "queue stride must retain its fixed device extent");
    static_assert(offsetof(VirtqNetQueue, desc) == 0,
                  "descriptor table must start at the queue base");
    static_assert(offsetof(VirtqNetQueue, avail) == 128,
                  "avail ring must follow eight descriptors");
    let desc: usize = (&virtio_net_queues as usize) + queue * sizeof(VirtqNetQueue) + offsetof(VirtqNetQueue, desc);
    let avail: usize = (&virtio_net_queues as usize) + queue * sizeof(VirtqNetQueue) + offsetof(VirtqNetQueue, avail);
    virtio_net_regs.queue_desc_low = (desc & 0xFFFFFFFF) as u32;
    virtio_net_regs.queue_desc_high = (desc >> 32) as u32;
    virtio_net_regs.queue_driver_low = (avail & 0xFFFFFFFF) as u32;
    virtio_net_regs.queue_driver_high = (avail >> 32) as u32;
    virtio_net_regs.queue_device_low = (used & 0xFFFFFFFF) as u32;
    virtio_net_regs.queue_device_high = (used >> 32) as u32;
    virtio_net_regs.queue_ready = 1;
    virtio_net_used_addr[queue] = used;
    return true;
}"""
NET_ACCESS = 'guarded_ref(guard, virtio_net_queues.queues)'
NET_RX_BODY = """{
    let guard = match block_device_try_take() {
        BlockDeviceTry::Busy => { return NetRxAcquire::None(ready); }
        BlockDeviceTry::Taken(taken) => { taken }
    };
    let result = virtio_net_rx_acquire_locked(guard, ready);
    block_device_give(guard);
    return result;
}"""
NET_REFILL_BODY = """{
    let guard = match block_device_try_take() {
        BlockDeviceTry::Busy => { return; }
        BlockDeviceTry::Taken(taken) => { taken }
    };
    virtio_net_rx_refill_locked(guard, r);
    block_device_give(guard);
}"""
NET_TX_BODY = """{
    let guard = block_device_take_unaccounted();
    desc_set(guard, 1, 0, address, length as isize, 0);
    avail_ring_set(guard, 1, 0, 0);
    r.tx_avail_idx = virtio_ring_index_next(r.tx_avail_idx);
    avail_publish(guard, 1, r.tx_avail_idx);
    atomic_word_fetch_add(&virtio_net_tx_submissions, 1);
    virtio_notify(1);
    block_device_give(guard);
}"""
NET_WRAPPERS = {'net_rx_acquire': NET_RX_BODY,
                'virtio_net_rx_refill': NET_REFILL_BODY,
                'virtio_net_tx_ring': NET_TX_BODY}


@per_file
def words(text):
    return tuple(m.group() for m in TOKEN.finditer(code_skeleton(text)))


def occurrences(haystack, needle):
    return [i for i in range(len(haystack)-len(needle)+1)
            if haystack[i:i+len(needle)] == needle]


def problems_in(files, *, net=False):
    # Two fixed reviewed boundaries, not a general address-escape grammar.
    driver,storage,global_name,setup,decl,header,closed_body,access = (
        (NET_DRIVER,NET_STORAGE,NET_GLOBAL,NET_SETUP,NET_DECL,NET_HEADER,NET_BODY,NET_ACCESS)
        if net else (DRIVER,STORAGE,GLOBAL,SETUP,DECL,HEADER,BODY,ACCESS))
    caller = "net_init" if net else "virtio_blk_init"
    wrapper_counts = {name:0 for name in NET_WRAPPERS} if net else {}
    errors = []
    accesses = 0
    setup_count = 0
    decl_count = 0
    for path,text in files.items():
        if not any(n in text for n in (storage,global_name,setup)):
            continue
        tokens,functions,_,_,bindings,_ = scan(text)
        ws = tuple(t[0] for t in tokens)
        allowed = set()
        def fail(i, message):
            line = text.count('\n',0,tokens[i][1])+1 if tokens else 1
            errors.append(f'{path}:{line}: {message}')
        def owner(i):
            return min((f for f in functions if f[0]<i<f[1]),
                       key=lambda f:f[1]-f[0],default=None)
        def name(f):
            return ws[f[3]-1] if f and f[3] and ws[f[3]-1]!='fn' else None
        if path == driver:
            for start in occurrences(ws,words(decl)):
                # A nested lookalike declaration is never the global mint.
                if owner(start) is not None: continue
                decl_count += 1
                allowed.update(range(start,start+len(words(decl))))
        for f in functions:
            a,b,_,p,q = f
            if net and name(f) in NET_WRAPPERS:
                wrapper_counts[name(f)] += 1
                if path != driver or ws[a:b+1] != words(NET_WRAPPERS[name(f)]):
                    fail(p,'net wrapper must try before mutation and release before waits/return')
            if name(f) != setup: continue
            setup_count += 1
            h = words(header)
            start = p-3  # private fn name (
            if (path != driver or start<0 or ws[start:a] != h or
                    ws[a:b+1] != words(closed_body) or owner(start) is not None):
                fail(p,'setup must retain its exact guarded header and closed MMIO-only body')
            else:
                allowed.update(range(start,b+1))
        for start in occurrences(ws,words(access)):
            f = owner(start)
            if path!=driver or f is None or not occurrences(ws[f[3]+1:f[4]],words(GUARD)):
                fail(start,'queue access requires its own borrowed block-device guard')
                continue
            # Nested functions and guard rebinding are outside this bounded
            # policy. The compiler checks the actual field/lock and lifetime.
            a,b,_,p,q = f
            shadow = any(ws[j]=='guard' and a<j<b for j in bindings)
            shadow |= any(ws[j:j+2]==('for','guard') for j in range(a,b-1))
            # Variant payload bindings have their own arm scope. The
            # compiler also refuses shadowing; keep this source policy
            # explicit rather than treating a shadow as the header's guard.
            for arrow in range(a+1,b):
                if ws[arrow] != '=>': continue
                boundary = max((j for j in range(a,arrow)
                                if ws[j] in ('{','}',';','=>')),default=a)
                shadow |= 'guard' in ws[boundary+1:arrow]
            if shadow or 'fn' in ws[a+1:b]:
                fail(start,'queue access cannot shadow its guard or capture it in a nested function')
                continue
            allowed.update(range(start,start+len(words(access))))
            accesses += 1
        for i,w in enumerate(ws):
            if w in (storage,global_name) and i not in allowed:
                fail(i,'queue container/wrapper may only be declared, guarded in place or minted in exact setup')
            if w==setup and i not in allowed:
                f=owner(i)
                calls = (words('virtio_queue_setup(guard, 0, VIRTIO_USED_NET_RX)'),
                         words('virtio_queue_setup(guard, 1, VIRTIO_USED_NET_TX)')) if net else (
                         words('virtio_blk_setup_queue(guard)'),)
                authority = False
                if f is not None:
                    if net:
                        authority = bool(occurrences(ws[f[0]+1:i],
                            words('let guard = block_device_take_unaccounted();')))
                        authority &= sum(ws[j]=='guard' and f[0]<j<f[1] for j in bindings)==1
                    else:
                        authority = bool(occurrences(ws[f[3]+1:f[4]],words(GUARD)))
                if (path!=driver or name(f)!=caller or not authority or
                        not any(ws[i:i+len(call)]==call for call in calls)):
                    fail(i,f'setup may only be called directly by guarded {caller}')
    if decl_count!=1: errors.append('queue storage must have exactly one reviewed private offset-zero wrapper/global declaration')
    if setup_count!=1: errors.append('queue storage must have exactly one reviewed setup function')
    if not accesses: errors.append('queue boundary must contain real guarded CPU accesses')
    for wrapper,count in wrapper_counts.items():
        if count!=1: errors.append(f'net boundary needs exactly one reviewed {wrapper} wrapper')
    return errors,accesses


def source_files():
    return {str(p.relative_to(ROOT)):p.read_text() for tree in ('kernel','linux_user')
            for p in (ROOT/tree).rglob('*.tkb') if not {'build','_build'} & set(p.relative_to(ROOT).parts)}


def main():
    files=source_files()
    errors,accesses=problems_in(files)
    net_errors,net_accesses=problems_in(files,net=True)
    errors += net_errors
    accesses += net_accesses
    for error in errors: print('ERROR virtio-queue-mints: '+error)
    if errors: return 1
    report_pass('virtio-queue-mints','block/net queues guarded in place; four address mints confined to closed setup MMIO sinks; RX tries before mutation',accesses=accesses)
    return 0


if __name__=='__main__': sys.exit(main())
