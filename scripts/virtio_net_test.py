#!/usr/bin/env python3
# Sends synthetic Ethernet frames to net_echo's virtio-net-device over a
# UDP-backed -netdev dgram (one UDP datagram == one raw Ethernet frame, no
# extra encapsulation -- see run_qemutest.sh for the exact QEMU flags) and
# verifies each reply has its source/destination MAC genuinely swapped
# while the EtherType and payload come back unchanged.
#
# Exit code only (0 = pass, 1 = fail); run_qemutest.sh prints the
# PASS/FAIL banner, matching how the other test helpers there work.

import socket
import sys

QEMU_HOST = "127.0.0.1"
QEMU_PORT = 17771   # must match -netdev dgram,...,local.port=... in run_qemutest.sh
LOCAL_PORT = 17772  # must match -netdev dgram,...,remote.port=... in run_qemutest.sh

DST_MAC = bytes([0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
SRC_MAC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
ETHERTYPE = bytes([0x88, 0xb5])  # IEEE 802 "local experimental" -- unused by any real protocol

# Frame sizes chosen to exercise: the empty-payload boundary, ordinary
# sizes, a size close to a standard 1500-byte MTU, and enough distinct
# sends (> QNUM=8 virtqueue depth) to exercise RX descriptor re-arm and
# used-ring index wraparound.
PAYLOAD_LENGTHS = [0, 1, 17, 64, 512, 1000, 1486] + list(range(0, 40))

RETRIES_PER_FRAME = 20
RETRY_TIMEOUT_SECS = 0.5


def build_frame(payload: bytes) -> bytes:
    return DST_MAC + SRC_MAC + ETHERTYPE + payload


def expected_reply(payload: bytes) -> bytes:
    # Same frame with source/destination MAC swapped; EtherType + payload unchanged.
    return SRC_MAC + DST_MAC + ETHERTYPE + payload


def main() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    sock.settimeout(RETRY_TIMEOUT_SECS)

    all_ok = True
    for n, plen in enumerate(PAYLOAD_LENGTHS):
        payload = bytes([(n + i) & 0xff for i in range(plen)])
        frame = build_frame(payload)
        want = expected_reply(payload)

        ok = False
        for attempt in range(RETRIES_PER_FRAME):
            # Resend on every attempt: harmless if the guest just hasn't
            # finished booting yet (net_echo's virtio_net_init posts RX
            # descriptors before the driver is up), and avoids a fixed
            # boot-time sleep before the first send.
            sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
            try:
                reply, _addr = sock.recvfrom(2000)
            except socket.timeout:
                continue
            if reply == want:
                ok = True
                break

        status = "PASS" if ok else "FAIL"
        print(f"  frame {n:2d} (payload={plen:4d} bytes): {status}")
        if not ok:
            all_ok = False

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
