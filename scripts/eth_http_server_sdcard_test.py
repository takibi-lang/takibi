#!/usr/bin/env python3
# Tests examples/http_server_sdcard/http_server_sdcard.tkb the same way a
# real browser would: over this machine's real TCP/IP stack (Python's
# http.client, ordinary sockets), same reasoning as
# scripts/eth_http_server_test.py -- see that file's module comment.
#
# Unlike http_server's own test (which checks a request counter embedded
# in a templated HTML page), this checks that the response body is the
# REAL content of examples/http_server_sdcard_install/
# http_server_sdcard_install.tkb's freshly-provisioned INDEX.TXT file --
# the whole point of this milestone (GitHub issue #97) is that the page
# came from the SD card, not a compiled-in template. The exact expected
# text is passed in via SDCARD_EXPECTED_TEXT (set by
# scripts/run_hwtest_net_ram.sh to the same string it wrote onto the card
# with mtools, so this script never hardcodes a copy that could drift).
#
# Flushes the ARP neighbor entry first, same cold-start reasoning as
# eth_http_server_test.py.
#
# Retries for a few seconds on transport failure: unlike every other
# hwcheck-net test, this one runs right after TWO back-to-back hardware
# resets (install_sdcard_image's own reset+resume, immediately followed by
# run_hwtest_net_ram.sh's separate ram_load_and_run reset+resume for this
# firmware) with none of the settling time the tests before it in the
# suite accumulate -- PHY autonegotiation plus this firmware's own
# net_init()/disk_initialize()/fat_mount() sequence needs a little real
# wall-clock time after the second reset before the board is actually
# ready to answer ARP. Confirmed by hand: a manual reset+load followed by
# a delayed request succeeds every time, while an immediate request can
# race ahead of readiness ("No route to host"). The other raw-socket
# hwcheck-net scripts cover the same PHY-autonegotiation latency via their
# own packet-level resend loops (see run_net_hw_test's comment); this
# script retries at the http.client level instead, since it uses ordinary
# sockets, not hand-built packets.
#
# Needs root (run via sudo, or `make hwcheck-net` which already does) for
# the `ip neigh flush` step. ETH_TEST_IFACE / SERVER_IP must match
# examples/common_stm32/netconfig.tkb.
#
# Exit code only (0 = pass, 1 = fail).

import http.client
import os
import subprocess
import sys
import time

IFACE = os.environ.get("ETH_TEST_IFACE", "enp4s0")
SERVER_IP = "192.168.10.2"  # must match netconfig.tkb's OUR_IP
SERVER_PORT = 80

REQUEST_TIMEOUT_SECS = 5
RETRY_TOTAL_SECS = 10
RETRY_INTERVAL_SECS = 0.5


def flush_arp_entry():
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


def fetch_with_retry() -> tuple:
    deadline = time.monotonic() + RETRY_TOTAL_SECS
    last_err = None
    while time.monotonic() < deadline:
        flush_arp_entry()
        try:
            return fetch()
        except OSError as e:
            last_err = e
            time.sleep(RETRY_INTERVAL_SECS)
    raise last_err


def main() -> int:
    expected = os.environ.get("SDCARD_EXPECTED_TEXT")
    if not expected:
        print("  SDCARD_EXPECTED_TEXT is required (set by run_hwtest_net_ram.sh)")
        return 1

    try:
        status, ctype, body = fetch_with_retry()
    except OSError as e:
        print(f"  request failed after {RETRY_TOTAL_SECS}s of retries: {e}")
        return 1

    ok = (
        status == 200 and
        ctype is not None and ctype.startswith("text/plain") and
        expected in body
    )
    print("  GET / returns real SD card content: %s" % ("PASS" if ok else "FAIL"))
    if not ok:
        print(f"  status={status} content-type={ctype!r}")
        print(f"  expected substring={expected!r}")
        print(f"  body={body!r}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
