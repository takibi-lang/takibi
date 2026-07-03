#!/usr/bin/env python3
# Tests examples/http_server/http_server_stm32.tkb the same way a real
# browser would: over this machine's real TCP/IP stack (Python's http.client,
# ordinary sockets), not a hand-crafted raw AF_PACKET script like the other
# four STM32 Ethernet hardware tests. That is deliberate -- http_server's
# entire point is being reachable from an unmodified browser, so exercising
# the real ARP-resolution + TCP handshake + HTTP request/close path the host
# kernel actually uses is a more meaningful check here than another
# hand-built packet script would be (see CLAUDE.md's HTTP Server /
# STM32 Ethernet section).
#
# Flushes the ARP neighbor entry for the board first, so the first request
# forces a genuine ARP resolution -- the same cold-start path a freshly
# opened browser tab takes -- rather than reusing a cache entry left over
# from an earlier manual `curl`/browser session.
#
# Sends two requests and checks the request counter increments between them
# (same determinism argument as scripts/http_server_test.py's QEMU version:
# a fresh board always starts at 0, and the retry-safe duplicate-suppression
# in tcp_echo_stm32.tkb's shared TCP core means a resent/retried request
# can't double-count).
#
# Needs root (run via sudo, or `make hwcheck-net` which already does) for
# the `ip neigh flush` step. ETH_TEST_IFACE / SERVER_IP must match
# examples/common_stm32/netconfig.tkb.
#
# Exit code only (0 = pass, 1 = fail).

import http.client
import os
import re
import subprocess
import sys

IFACE = os.environ.get("ETH_TEST_IFACE", "enp4s0")
SERVER_IP = "192.168.10.2"  # must match netconfig.tkb's OUR_IP
SERVER_PORT = 80

REQUEST_TIMEOUT_SECS = 5


def flush_arp_entry():
    # Best-effort: an absent entry (nothing cached yet) is not an error, and
    # the ARP resolution the real request below performs is what's actually
    # being tested, not this flush itself.
    subprocess.run(
        ["ip", "neigh", "flush", "dev", IFACE, "to", SERVER_IP],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def fetch() -> tuple:
    """Returns (status, content_type, body) or raises on transport failure."""
    conn = http.client.HTTPConnection(SERVER_IP, SERVER_PORT, timeout=REQUEST_TIMEOUT_SECS)
    try:
        conn.request("GET", "/")
        resp = conn.getresponse()
        body = resp.read().decode("us-ascii")
        return resp.status, resp.getheader("Content-Type"), body
    finally:
        conn.close()


def extract_count(body: str) -> int:
    m = re.search(r"Request <span class='count'>#(\d+)</span>", body)
    if m is None:
        raise ValueError("request counter not found in response body")
    return int(m.group(1))


def main() -> int:
    flush_arp_entry()

    try:
        status1, ctype1, body1 = fetch()
    except OSError as e:
        print(f"  first request failed: {e}")
        return 1

    ok1 = (
        status1 == 200 and
        ctype1 is not None and ctype1.startswith("text/html") and
        "Hello from Takibi!" in body1
    )
    print("  first request (#1):                %s" % ("PASS" if ok1 else "FAIL"))
    if not ok1:
        print(f"  status={status1} content-type={ctype1!r}")

    try:
        status2, _ctype2, body2 = fetch()
    except OSError as e:
        print(f"  second request failed: {e}")
        return 1

    try:
        count1 = extract_count(body1) if ok1 else None
        count2 = extract_count(body2)
    except ValueError as e:
        print(f"  {e}")
        count1 = count2 = None

    ok2 = (
        status2 == 200 and
        count1 is not None and count2 is not None and
        count2 == count1 + 1
    )
    print("  second request (#2, counter bump): %s" % ("PASS" if ok2 else "FAIL"))
    if not ok2:
        print(f"  count1={count1} count2={count2}")

    return 0 if (ok1 and ok2) else 1


if __name__ == "__main__":
    sys.exit(main())
