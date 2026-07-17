#!/usr/bin/env python3
# Tests examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos.tkb over
# this machine's real TCP/IP stack, using a raw socket with each request
# sent as ONE sendall() call (request line + headers + body combined),
# rather than http.client. This is deliberate, not a style choice: Python's
# http.client reliably splits a PUT's headers and body into two separate
# send() calls, which this firmware's http_start_response does not
# reassemble across TCP segments (see kvs_server_sdcard_rtos.tkb's own
# header comment) -- every PUT sent that way gets a spurious 400 Bad
# Request (Content-Length says N, but the segment that actually reached
# the server carried 0 body bytes). curl avoids this by writing header+
# body in one call; this script does the same thing explicitly so it is
# not at the mercy of whichever HTTP client library's internal buffering
# happens to be in use.
#
# Two phases, selected by the KVS_TEST_PHASE environment variable:
#
#   full (default): exercises PUT/GET/DELETE/LIST the same way
#   scripts/kvs_test.py does over QEMU, then PUTs one extra key
#   ("persist_probe") and deliberately leaves it behind -- QEMU has no
#   persistence to prove, but this firmware does, and this key is what the
#   second phase checks for after a real board reset.
#
#   verify_persistence: run_hwtest_net_ram.sh invokes this in a SEPARATE
#   process after a second ram_load_and_run (a genuine MCU reset, SD card
#   physically untouched) with no reprovisioning in between. It only GETs
#   "persist_probe" and checks the value written by the `full` phase is
#   still there, then deletes it as cleanup. This is the actual
#   persistence-survives-a-reset proof this milestone exists to make --
#   QEMU's own scripts/kvs_test.py has no analog for it (a fresh QEMU
#   process keeps no state across a restart at all).
#
# Flushes the ARP neighbor entry and retries with settling time, same
# reasoning as eth_http_server_sdcard_test.py: this runs right after a
# hardware reset, and PHY autonegotiation plus this firmware's own
# net_init()/disk_initialize()/SD-table-load sequence needs real
# wall-clock time to finish before the board answers ARP.
#
# Needs root (run via sudo, or `make hwcheck-net` which already does) for
# the `ip neigh flush` step. ETH_TEST_IFACE / SERVER_IP must match
# examples/common_stm32/netconfig.tkb.
#
# Exit code only (0 = pass, 1 = fail).

import os
import socket
import subprocess
import sys
import time

IFACE = os.environ.get("ETH_TEST_IFACE", "enp4s0")
SERVER_IP = "192.168.10.2"  # must match netconfig.tkb's OUR_IP
SERVER_PORT = 80
PHASE = os.environ.get("KVS_TEST_PHASE", "full")

REQUEST_TIMEOUT_SECS = 5
RETRY_TOTAL_SECS = 10
RETRY_INTERVAL_SECS = 0.5

PERSIST_KEY = "persist_probe"
PERSIST_VALUE = b"survived a real reset"


def flush_arp_entry():
    subprocess.run(
        ["ip", "neigh", "flush", "dev", IFACE, "to", SERVER_IP],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def build_request(method: str, path: str, body: bytes = None) -> bytes:
    header_lines = [f"{method} {path} HTTP/1.1", f"Host: {SERVER_IP}"]
    if body is not None:
        header_lines.append(f"Content-Length: {len(body)}")
    header_lines.append("Connection: close")
    head = "\r\n".join(header_lines).encode() + b"\r\n\r\n"
    return head + (body or b"")


def parse_http_response(raw: bytes):
    if b"\r\n\r\n" not in raw:
        return None
    head, body = raw.split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    try:
        status = int(lines[0].split(b" ")[1])
    except (IndexError, ValueError):
        return None
    return status, body


def request(method: str, path: str, body: bytes = None) -> tuple:
    """Returns (status, body) or raises OSError on transport failure."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(REQUEST_TIMEOUT_SECS)
    try:
        s.connect((SERVER_IP, SERVER_PORT))
        s.sendall(build_request(method, path, body))
        chunks = []
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        s.close()
    parsed = parse_http_response(b"".join(chunks))
    if parsed is None:
        raise OSError("malformed or empty HTTP response")
    return parsed


def request_with_retry(method: str, path: str, body: bytes = None) -> tuple:
    deadline = time.monotonic() + RETRY_TOTAL_SECS
    last_err = None
    while time.monotonic() < deadline:
        flush_arp_entry()
        try:
            return request(method, path, body)
        except OSError as e:
            last_err = e
            time.sleep(RETRY_INTERVAL_SECS)
    raise last_err


def expect(desc: str, method: str, path: str, body: bytes,
           want_status: int, want_body: bytes = None) -> bool:
    try:
        status, resp_body = request_with_retry(method, path, body)
    except OSError as e:
        print("  [%s] FAIL: request failed after %ds of retries: %s" %
              (desc, RETRY_TOTAL_SECS, e))
        return False
    ok = (status == want_status) and (want_body is None or resp_body == want_body)
    if not ok:
        print("  [%s] FAIL: got status=%s body=%r, want status=%d body=%r" %
              (desc, status, resp_body, want_status, want_body))
    return ok


def run_full() -> bool:
    ok = True
    ok &= expect("GET missing key", "GET", "/keys/nope", None, 404, b"not found\n")
    ok &= expect("PUT alpha=one (new)", "PUT", "/keys/alpha", b"one", 201, b"")
    ok &= expect("GET alpha", "GET", "/keys/alpha", None, 200, b"one")
    ok &= expect("PUT alpha=two (overwrite)", "PUT", "/keys/alpha", b"two", 200, b"")
    ok &= expect("GET alpha after overwrite", "GET", "/keys/alpha", None, 200, b"two")

    status, list_body = request_with_retry("GET", "/keys")
    if status != 200 or b"alpha" not in list_body.split(b"\n"):
        print("  [GET /keys] FAIL: status=%s body=%r" % (status, list_body))
        ok = False

    ok &= expect("DELETE alpha", "DELETE", "/keys/alpha", None, 200, b"")
    ok &= expect("GET alpha after delete", "GET", "/keys/alpha", None, 404, b"not found\n")

    # Left behind on purpose -- verify_persistence checks this survives a
    # real board reset with no reprovisioning in between.
    ok &= expect("PUT persist_probe (left behind)", "PUT", "/keys/" + PERSIST_KEY,
                 PERSIST_VALUE, 201, b"")
    return ok


def run_verify_persistence() -> bool:
    ok = True
    ok &= expect("GET persist_probe (after reset)", "GET", "/keys/" + PERSIST_KEY,
                 None, 200, PERSIST_VALUE)
    ok &= expect("DELETE persist_probe (cleanup)", "DELETE", "/keys/" + PERSIST_KEY,
                 None, 200, b"")
    return ok


def main() -> int:
    if PHASE == "verify_persistence":
        ok = run_verify_persistence()
    elif PHASE == "full":
        ok = run_full()
    else:
        print("  unknown KVS_TEST_PHASE: %r" % PHASE)
        return 1
    print("  KVS_TEST_PHASE=%s: %s" % (PHASE, "PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
