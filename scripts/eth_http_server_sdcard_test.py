#!/usr/bin/env python3
# Tests examples/http_server_sdcard/http_server_sdcard.tkb the same way a
# real browser would: over this machine's real TCP/IP stack (Python's
# http.client, ordinary sockets), same reasoning as
# scripts/eth_http_server_test.py -- see that file's module comment.
#
# Unlike http_server's own test (which checks a request counter embedded
# in a templated HTML page), this checks that the response body is the
# REAL content of the freshly-provisioned examples/sdcard_content files --
# the whole point of this milestone (GitHub issue #97) is that the page
# came from the SD card, not a compiled-in template. Expected bodies are
# read from the same content directory used by the provisioning script, so
# the checker does not keep a duplicate copy of page contents.
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
CONTENT_DIR = os.environ.get("SDCARD_CONTENT_DIR", "examples/sdcard_content")

REQUEST_TIMEOUT_SECS = 5
RETRY_TOTAL_SECS = 10
RETRY_INTERVAL_SECS = 0.5


def flush_arp_entry():
    subprocess.run(
        ["ip", "neigh", "flush", "dev", IFACE, "to", SERVER_IP],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def fetch(path: str) -> tuple:
    """Returns (status, content_type, body) or raises on transport failure."""
    conn = http.client.HTTPConnection(SERVER_IP, SERVER_PORT, timeout=REQUEST_TIMEOUT_SECS)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        return resp.status, resp.getheader("Content-Type"), body
    finally:
        conn.close()


def fetch_with_retry(path: str) -> tuple:
    deadline = time.monotonic() + RETRY_TOTAL_SECS
    last_err = None
    while time.monotonic() < deadline:
        flush_arp_entry()
        try:
            return fetch(path)
        except OSError as e:
            last_err = e
            time.sleep(RETRY_INTERVAL_SECS)
    raise last_err


def check_path(path: str, expected: bytes, content_type: str) -> bool:
    try:
        status, ctype, body = fetch_with_retry(path)
    except OSError as e:
        print(f"  request {path} failed after {RETRY_TOTAL_SECS}s of retries: {e}")
        return False

    ok = (
        status == 200 and
        ctype is not None and ctype.startswith(content_type) and
        body == expected
    )
    print("  GET %s returns real SD card content: %s" %
          (path, "PASS" if ok else "FAIL"))
    if not ok:
        print(f"  status={status} content-type={ctype!r}")
        print(f"  expected body={expected!r}")
        print(f"  body={body!r}")
    return ok


def main() -> int:
    try:
        with open(os.path.join(CONTENT_DIR, "INDEX.HTM"), "rb") as f:
            index_expected = f.read()
        with open(os.path.join(CONTENT_DIR, "ABOUT.HTM"), "rb") as f:
            about_expected = f.read()
        with open(os.path.join(CONTENT_DIR, "ICON.PNG"), "rb") as f:
            icon_expected = f.read()
    except OSError as e:
        print(f"  failed to read SD card content directory {CONTENT_DIR!r}: {e}")
        return 1

    ok = check_path("/", index_expected, "text/html")
    ok = check_path("/ABOUT.HTM", about_expected, "text/html") and ok
    ok = check_path("/ICON.PNG", icon_expected, "image/png") and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
