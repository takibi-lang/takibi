#!/usr/bin/env python3
"""Bridge host HTTP connections to Takibi's UDP-framed Ethernet peer."""

import socket
import sys

import kernel_net_test as peer


def receive_request(connection: socket.socket) -> bytes:
    request = bytearray()
    while b"\r\n\r\n" not in request and len(request) < 16384:
        part = connection.recv(4096)
        if not part:
            break
        request.extend(part)
    return bytes(request)


def request_path(request: bytes) -> str | None:
    first_line = request.split(b"\r\n", 1)[0].split()
    if len(first_line) != 3 or first_line[0] != b"GET":
        return None
    try:
        return first_line[1].decode("ascii").split("?", 1)[0]
    except UnicodeDecodeError:
        return None


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: kernel_http_bridge.py QEMU_UDP PEER_UDP HOST_TCP",
              file=sys.stderr)
        return 2
    qemu_port, peer_port, host_port = map(int, sys.argv[1:])
    ethernet = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ethernet.bind((peer.QEMU_HOST, peer_port))
    ethernet.settimeout(peer.RETRY_TIMEOUT_SECS)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((peer.QEMU_HOST, host_port))
    listener.listen(8)
    print(f"HTTP bridge listening on 127.0.0.1:{host_port}", flush=True)

    connection_number = 0
    while True:
        connection, _address = listener.accept()
        with connection:
            path = request_path(receive_request(connection))
            if path is None:
                connection.sendall(b"HTTP/1.0 400 Bad Request\r\n\r\n")
                continue
            client_port = 44000 + (connection_number % 1000)
            client_isn = 10000 + (connection_number % 4_000_000) * 1000
            connection_number += 1
            response = peer.raw_http_response(
                ethernet, client_port, client_isn, path
            )
            if response is None:
                connection.sendall(b"HTTP/1.0 502 Bad Gateway\r\n\r\n")
                continue
            connection.sendall(response)


if __name__ == "__main__":
    raise SystemExit(main())
