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
# Waits (bounded) for the board's Ethernet link before that first request,
# because the runner starts the board and runs this script with nothing in
# between. See fetch_once_link_is_up for why only the unreachable errnos
# are waited out and why that keeps the counter check below honest.
#
# Sends two requests and checks the request counter increments between them
# (same determinism argument as scripts/http_server_test.py's QEMU version:
# a fresh board always starts at 0, and the retry-safe duplicate-suppression
# in tcp_echo_stm32.tkb's shared TCP core means a resent/retried request
# can't double-count).
#
# Needs root (run via sudo, or `make hwcheck-net` which already does) for
# the `ip neigh flush` step. ETH_TEST_IFACE / ETH_TEST_SUBNET must match
# the selected target's netconfig.tkb (STM32 remains the default).
#
# Exit code only (0 = pass, 1 = fail).

import errno
import http.client
import os
import re
import subprocess
import sys
import time

IFACE = os.environ.get("ETH_TEST_IFACE", "enp4s0")
SERVER_IP = os.environ.get("ETH_TEST_SUBNET", "192.168.10") + ".2"
SERVER_PORT = 80

REQUEST_TIMEOUT_SECS = 5

# How long to keep waiting for the board to become reachable at all before
# giving up on it. This is not slack added to the request itself -- see
# fetch_once_link_is_up below for what it is actually waiting for, and why
# waiting is not the same as retrying.
LINK_WAIT_SECS = 20
LINK_POLL_SECS = 0.25


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


def fetch_once_link_is_up() -> tuple:
    """The first fetch, waiting out the board's PHY link negotiation.

    This runner starts the board and runs this script immediately, with no
    readiness step in between (scripts/run_hwtest_net_ram.sh's
    run_net_hw_test), so the first request races the board's boot and
    `phy_init`'s Ethernet auto-negotiation -- which takes long enough that
    AGENTS.md records this lane's "occasional link-negotiation flakiness"
    as a known property. The other four STM32 Ethernet tests never saw it
    because they are raw AF_PACKET scripts that retry every frame
    (eth_tcp_echo_test.py's send_and_wait); this one goes through the host
    kernel's own stack and had exactly one attempt.

    Retrying is only sound because of WHICH errors are retried.
    EHOSTUNREACH and ENETUNREACH are generated locally, by the neighbour
    subsystem, when nothing can be sent to the address -- so the board
    cannot have seen a request, and its counter cannot have moved. That
    keeps the #1/#2 counter check below meaning what it means. A timeout or
    a refused connection is NOT retried: those can mean the request
    arrived and its response was lost, which would silently break exactly
    that check.

    The ARP flush and the cold resolution it forces are untouched: this
    waits for the LINK, and the first request that gets through still does
    a genuine from-scratch ARP resolution.
    """
    deadline = time.monotonic() + LINK_WAIT_SECS
    waited = False
    while True:
        try:
            result = fetch()
            if waited:
                print("  (waited %.1fs for the board's link)"
                      % (LINK_WAIT_SECS - (deadline - time.monotonic())))
            return result
        except OSError as e:
            if e.errno not in (errno.EHOSTUNREACH, errno.ENETUNREACH):
                raise
            if time.monotonic() >= deadline:
                raise
            waited = True
            time.sleep(LINK_POLL_SECS)


def extract_count(body: str) -> int:
    m = re.search(r"Request <span class='count'>#(\d+)</span>", body)
    if m is None:
        raise ValueError("request counter not found in response body")
    return int(m.group(1))


def main() -> int:
    flush_arp_entry()

    try:
        status1, ctype1, body1 = fetch_once_link_is_up()
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
