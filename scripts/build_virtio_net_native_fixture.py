#!/usr/bin/env python3
"""Copy the real virtio-net driver for a native, deterministic policy fixture.

Only the IRQ handler's AArch64 SEV builtin is replaced by a no-op provider:
AMD64 has no interrupt_notify lowering. The fixture never calls this handler;
clock and device-written RAM are controlled by the native support file. Every
submission, completion, timeout and queue-disable statement stays verbatim.

The occupancy import is dropped too: it reaches AArch64 kernel files, and the
driver needs only the MachineStopped name for DDB's look (#1164), which the
fixture never calls. The native support file declares that name.
"""
import argparse
from pathlib import Path

from layout_text import AnchorCountError, layout_replace_once


SHADOW_READERS = """
// The shadows, read-only, for the native fixture's checks
// (linux_user/virtio_net_tx).
struct VirtioNetShadows {
    rx_used_seen: VirtioRingIndex;
    tx_used_seen: VirtioRingIndex;
    rx_avail_idx: VirtioRingIndex;
    tx_avail_idx: VirtioRingIndex;
}
fn virtio_net_shadows(r: borrow NetRxCanAcquire[net]) -> VirtioNetShadows {
    let mut v: VirtioNetShadows = {
        r.rx_used_seen, r.tx_used_seen, r.rx_avail_idx, r.tx_avail_idx
    };
    return v;
}
fn virtio_net_rx_slot(r: borrow NetRxCanAcquire[net], index: {0..<8 as usize}) -> usize {
    return r.rx_desc_pkt.slot[index] as usize;
}
fn virtio_net_packet_shadows(p: borrow NetPacket[pb, po, net]) -> VirtioNetShadows {
    return virtio_net_shadows(p.ready);
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.source.read_text()
    try:
        source = layout_replace_once(source, "    interrupt_notify();", "    virtio_fixture_notify();")
    except AnchorCountError:
        raise SystemExit("virtio-net native fixture: expected exactly one IRQ notify anchor") from None
    try:
        source = layout_replace_once(source, 'use "kernel/lib/occupancy.tkb";\n', "")
    except AnchorCountError:
        raise SystemExit("virtio-net native fixture: expected exactly one occupancy import") from None
    # GitHub issue #1416: the ring shadows are the capability's private
    # fields; the fixture's checks read them through these, which only the
    # driver's own file (this copy) can define.
    source += SHADOW_READERS
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(source)


if __name__ == "__main__":
    main()
