#!/usr/bin/env python3
"""Real-link integration test for examples/kvs_server/kvs_server.tkb."""

import os
import socket
import subprocess
import sys

IFACE = os.environ.get("ETH_TEST_IFACE", "enp4s0")
SERVER_IP = os.environ.get("ETH_TEST_SUBNET", "192.168.10") + ".2"
SERVER_PORT = 80
TIMEOUT_SECS = 5


def flush_arp_entry():
    subprocess.run(["ip", "neigh", "flush", "dev", IFACE, "to", SERVER_IP],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def request(method: str, path: str, body: bytes = None, content_length=None):
    lines = [f"{method} {path} HTTP/1.1", f"Host: {SERVER_IP}"]
    if body is not None and content_length != "omit":
        length = len(body) if content_length is None else content_length
        lines.append(f"Content-Length: {length}")
    lines.append("Connection: close")
    wire = "\r\n".join(lines).encode() + b"\r\n\r\n" + (body or b"")

    with socket.create_connection((SERVER_IP, SERVER_PORT), TIMEOUT_SECS) as sock:
        # One write is intentional: this server rejects a PUT body split
        # across TCP segments rather than reassembling it.
        sock.sendall(wire)
        chunks = []
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)

    raw = b"".join(chunks)
    if b"\r\n\r\n" not in raw:
        raise OSError("malformed or empty HTTP response")
    head, response_body = raw.split(b"\r\n\r\n", 1)
    try:
        status = int(head.split(b"\r\n", 1)[0].split(b" ")[1])
    except (IndexError, ValueError) as exc:
        raise OSError("malformed HTTP status") from exc
    return status, response_body


def expect(desc, method, path, body, status, response_body=None, content_length=None):
    try:
        got_status, got_body = request(method, path, body, content_length)
    except OSError as exc:
        print(f"  [{desc}] FAIL: {exc}")
        return False
    ok = got_status == status and (response_body is None or got_body == response_body)
    if not ok:
        print(f"  [{desc}] FAIL: got status={got_status} body={got_body!r}")
    return ok


def test_basic():
    ok = expect("GET missing", "GET", "/keys/nope", None, 404, b"not found\n")
    ok &= expect("PUT new", "PUT", "/keys/alpha", b"one", 201, b"")
    ok &= expect("GET", "GET", "/keys/alpha", None, 200, b"one")
    ok &= expect("PUT overwrite", "PUT", "/keys/alpha", b"two", 200, b"")
    ok &= expect("GET overwrite", "GET", "/keys/alpha", None, 200, b"two")
    ok &= expect("DELETE", "DELETE", "/keys/alpha", None, 200, b"")
    ok &= expect("GET deleted", "GET", "/keys/alpha", None, 404, b"not found\n")
    return ok


def test_parser_errors():
    ok = expect("bad key length", "PUT", "/keys/" + "a" * 33, b"v", 400, b"bad request\n")
    ok &= expect("bad key char", "PUT", "/keys/ba*d", b"v", 400, b"bad request\n")
    ok &= expect("large value", "PUT", "/keys/big", b"x" * 129, 400, b"bad request\n")
    ok &= expect("length mismatch", "PUT", "/keys/mismatch", b"abc", 400,
                 b"bad request\n", 100)
    ok &= expect("unknown path", "GET", "/nope", None, 404, b"not found\n")
    ok &= expect("PUT collection", "PUT", "/keys", b"", 405, b"method not allowed\n", "omit")
    ok &= expect("DELETE collection", "DELETE", "/keys", None, 405, b"method not allowed\n")
    return ok


def test_no_content_length():
    ok = expect("PUT no Content-Length", "PUT", "/keys/nocl", b"raw", 201, b"", "omit")
    ok &= expect("GET no Content-Length value", "GET", "/keys/nocl", None, 200, b"raw")
    ok &= expect("DELETE no Content-Length value", "DELETE", "/keys/nocl", None, 200, b"")
    return ok


def test_full_table():
    ok = True
    for i in range(16):
        ok &= expect(f"fill k{i:02d}", "PUT", f"/keys/k{i:02d}", b"v", 201, b"")
    ok &= expect("table full", "PUT", "/keys/k16", b"v", 507, b"table full\n")
    try:
        status, body = request("GET", "/keys")
        keys = {line for line in body.split(b"\n") if line}
        wanted = {f"k{i:02d}".encode() for i in range(16)}
        list_ok = status == 200 and keys == wanted
    except OSError as exc:
        print(f"  [LIST full] FAIL: {exc}")
        list_ok = False
    ok &= list_ok
    ok &= expect("overwrite full", "PUT", "/keys/k07", b"v2", 200, b"")
    ok &= expect("GET overwritten", "GET", "/keys/k07", None, 200, b"v2")
    ok &= expect("delete tombstone", "DELETE", "/keys/k03", None, 200, b"")
    ok &= expect("reuse tombstone", "PUT", "/keys/fresh", b"v", 201, b"")
    ok &= expect("GET fresh", "GET", "/keys/fresh", None, 200, b"v")
    return ok


def main():
    flush_arp_entry()
    tests = [("set/get/overwrite/delete", test_basic),
             ("put without content-length", test_no_content_length),
             ("parser/error cases", test_parser_errors),
             ("table full/list/tombstone reuse", test_full_table)]
    all_ok = True
    for name, test in tests:
        ok = test()
        print("  %-34s %s" % (name, "PASS" if ok else "FAIL"))
        all_ok &= ok
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
