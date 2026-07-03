#!/usr/bin/env python3
# Sends synthetic Ethernet frames to the real STM32F746G-DISCOVERY board's
# Ethernet MAC (examples/net_echo/net_echo_stm32.tkb, see
# examples/common_stm32/eth.tkb) over a raw AF_PACKET socket on a physical
# point-to-point link, and verifies each reply has its source/destination
# MAC genuinely swapped while the EtherType and payload come back unchanged.
# Same verification shape as scripts/virtio_net_test.py (the QEMU/virtio-net
# counterpart) -- see that file for the non-hardware version.
#
# Two things differ from the QEMU version because this runs over a real
# physical link instead of a software queue:
#  - Needs CAP_NET_RAW (run via sudo, or `make hwtest-net-echo-stm32` which
#    already does) and ETH_TEST_IFACE pointed at the wired interface (this
#    devcontainer's confirmed point-to-point NIC is enp4s0, the default).
#  - Payload lengths are kept >= 46 bytes so every frame is already at
#    Ethernet's 60-byte minimum. Below that, the sending NIC driver pads the
#    frame up to 60 bytes before it hits the wire, and STM32's MAC
#    (APCS = automatic pad/CRC stripping) can only strip that pad for
#    IEEE802.3 length-field frames -- our EtherType (0x88b5, >= 0x600) marks
#    this as Ethernet II, which carries no length field for the MAC to strip
#    against, so any host-added padding would come back in the reply
#    unchanged. Not a bug in the driver, just a physical-layer detail the
#    QEMU/virtio-net test never has to deal with (no real minimum frame size
#    there) -- see this project's STM32 Ethernet plan for the reasoning.
#
# Exit code only (0 = pass, 1 = fail).

import os
import socket
import sys
import time

IFACE = os.environ.get("ETH_TEST_IFACE", "enp4s0")
ETHERTYPE = bytes([0x88, 0xb5])  # IEEE 802 "local experimental" -- unused by any real protocol
DST_MAC = bytes([0xff, 0xff, 0xff, 0xff, 0xff, 0xff])  # broadcast: STM32 driver accepts any dest (MACFFR.RA=1)

# >= 46 so every frame (14-byte header + payload) is already >= 60 bytes --
# see the module comment above for why smaller frames are not tested here.
PAYLOAD_LENGTHS = [46, 60, 128, 512, 1000, 1486]

RETRIES_PER_FRAME = 20
RETRY_TIMEOUT_SECS = 0.5


def read_iface_mac(iface: str) -> bytes:
    with open(f"/sys/class/net/{iface}/address") as f:
        return bytes(int(b, 16) for b in f.read().strip().split(":"))


def build_frame(src_mac: bytes, payload: bytes) -> bytes:
    return DST_MAC + src_mac + ETHERTYPE + payload


def expected_reply(src_mac: bytes, payload: bytes) -> bytes:
    # Same frame with source/destination MAC swapped; EtherType + payload unchanged.
    return src_mac + DST_MAC + ETHERTYPE + payload


def main() -> int:
    if not os.path.exists(f"/sys/class/net/{IFACE}"):
        print(f"error: interface {IFACE!r} not found -- set ETH_TEST_IFACE?", file=sys.stderr)
        return 1
    src_mac = read_iface_mac(IFACE)

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88b5))
    sock.bind((IFACE, 0))
    sock.settimeout(RETRY_TIMEOUT_SECS)

    all_ok = True
    for n, plen in enumerate(PAYLOAD_LENGTHS):
        payload = bytes([(n + i) & 0xff for i in range(plen)])
        frame = build_frame(src_mac, payload)
        want = expected_reply(src_mac, payload)

        ok = False
        for attempt in range(RETRIES_PER_FRAME):
            # Resend on every attempt: harmless if the board just hasn't
            # finished booting/negotiating link yet.
            sock.send(frame)
            deadline = time.monotonic() + RETRY_TIMEOUT_SECS
            while time.monotonic() < deadline:
                try:
                    reply = sock.recv(2000)
                except socket.timeout:
                    break
                if reply[: len(frame)] == frame:
                    continue  # AF_PACKET loops our own outgoing frame back to us -- skip it
                # Prefix-compare rather than exact-equality: tolerates any
                # trailing NIC-added padding on the reply (see module
                # comment), while still verifying the real content is right.
                if reply[: len(want)] == want:
                    ok = True
                    break
            if ok:
                break

        status = "PASS" if ok else "FAIL"
        print(f"  frame {n:2d} (payload={plen:4d} bytes): {status}")
        if not ok:
            all_ok = False

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
