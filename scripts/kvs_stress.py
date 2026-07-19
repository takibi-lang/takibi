#!/usr/bin/env python3
# Concurrent load generator for the KVS HTTP server (GitHub issue #135),
# used to characterize eventual SD persistence and the concurrent TCP
# implementation under real load.
#
# Uses raw sockets, one sendall() per request (request line + headers +
# body combined), same reasoning as eth_kvs_server_stm32_test.py: this
# firmware does not reassemble a request split across multiple TCP
# segments, and this tool wants tight control over request pacing/framing
# rather than being at the mercy of an HTTP client library's internal
# buffering.
#
# --concurrency N spawns N worker threads, each looping PUT/GET/DELETE/
# LIST requests against the server for the configured duration. The
# shared TCP core accepts MAX_CONNS=24 simultaneous connections. Higher
# concurrency deliberately exercises overload behavior: excess SYNs may be
# retried while all twenty-four slots are occupied.
#
# Works against any host:port (QEMU's qemu-kvs SLIRP hostfwd, or a real
# board over Ethernet) -- defaults match the STM32 board's netconfig.tkb.
#
# No external dependencies (stdlib only), matching every other script in
# this directory.

import argparse
import random
import socket
import struct
import sys
import threading
import time


def build_request(method: str, path: str, host: str, body: bytes = None) -> bytes:
    header_lines = [f"{method} {path} HTTP/1.1", f"Host: {host}"]
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


def do_request(host: str, port: int, method: str, path: str, body: bytes,
                timeout: float):
    """Returns (status_or_None, elapsed_secs, error_str_or_None)."""
    start = time.monotonic()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            try:
                s.connect((host, port))
                s.sendall(build_request(method, path, host, body))
                chunks = []
                while True:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    chunks.append(chunk)
            except OSError:
                # Do not leave a timed-out stress connection retransmitting
                # in FIN-WAIT for the next board reload/measurement.
                try:
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                 struct.pack("ii", 1, 0))
                except OSError:
                    pass
                raise
        finally:
            s.close()
        elapsed = time.monotonic() - start
        parsed = parse_http_response(b"".join(chunks))
        if parsed is None:
            return None, elapsed, "malformed or empty response"
        status, _ = parsed
        return status, elapsed, None
    except OSError as e:
        return None, time.monotonic() - start, str(e)


class Metrics:
    def __init__(self):
        self._lock = threading.Lock()
        self._records = []  # (op, status_or_None, elapsed_secs, error_or_None)

    def record(self, op: str, status, elapsed: float, error):
        with self._lock:
            self._records.append((op, status, elapsed, error))

    def snapshot(self):
        with self._lock:
            return list(self._records)


def worker(stop_event: threading.Event, host: str, port: int, key_space: int,
           put_ratio: float, get_ratio: float, delete_ratio: float,
           value_size: int, timeout: float, fixed_key: str, metrics: Metrics):
    rng = random.Random()
    value = bytes(rng.randrange(256) for _ in range(value_size))
    get_threshold = put_ratio + get_ratio
    delete_threshold = get_threshold + delete_ratio
    while not stop_event.is_set():
        r = rng.random()
        if fixed_key:
            key = fixed_key
        else:
            key = "k%02d" % rng.randrange(key_space)
        if r < put_ratio:
            op = "PUT"
            status, elapsed, err = do_request(host, port, "PUT", "/keys/" + key, value, timeout)
        elif r < get_threshold:
            op = "GET"
            status, elapsed, err = do_request(host, port, "GET", "/keys/" + key, None, timeout)
        elif r < delete_threshold:
            op = "DELETE"
            status, elapsed, err = do_request(host, port, "DELETE", "/keys/" + key, None, timeout)
        else:
            op = "LIST"
            status, elapsed, err = do_request(host, port, "GET", "/keys", None, timeout)
        metrics.record(op, status, elapsed, err)
        if err is not None:
            # Small backoff on connection-level failure (the server busy
            # with someone else's connection, most likely) so a high
            # --concurrency doesn't degenerate into a hot spin loop that
            # burns client CPU without generating meaningful additional
            # load on the board.
            time.sleep(rng.uniform(0.005, 0.02))


def percentile(sorted_values, p: float) -> float:
    if not sorted_values:
        return 0.0
    idx = min(len(sorted_values) - 1, int(len(sorted_values) * p))
    return sorted_values[idx]


def report(records, wall_secs: float):
    if not records:
        print("No requests completed.")
        return

    by_op = {}
    for op, status, elapsed, err in records:
        by_op.setdefault(op, []).append((status, elapsed, err))

    total = len(records)
    print("\n%d requests in %.1fs (%.1f req/s)\n" % (total, wall_secs, total / wall_secs))

    print("%-8s%8s%8s%8s%10s%10s%10s%10s" %
          ("op", "count", "ok", "errs", "p50 ms", "p95 ms", "p99 ms", "max ms"))
    for op, entries in sorted(by_op.items()):
        latencies = sorted(e[1] for e in entries)
        ok = sum(1 for status, _, err in entries
                 if err is None and status is not None and status < 500)
        errs = len(entries) - ok
        p50 = percentile(latencies, 0.50) * 1000
        p95 = percentile(latencies, 0.95) * 1000
        p99 = percentile(latencies, 0.99) * 1000
        pmax = latencies[-1] * 1000 if latencies else 0.0
        print("%-8s%8d%8d%8d%10.1f%10.1f%10.1f%10.1f" %
              (op, len(entries), ok, errs, p50, p95, p99, pmax))

    # Keep transport failures separate from HTTP error responses. With the
    # N=24 server these indicate packet loss, slot exhaustion, or recovery
    # failure rather than an application-level status.
    conn_errors = [err for _, _, _, err in records if err is not None]
    if conn_errors:
        print("\n%d/%d requests failed at the connection/transport level "
              "(timeout, refused, reset); these are not HTTP status errors."
              % (len(conn_errors), total))
        print("  sample error: %r" % conn_errors[0])

    status_counts = {}
    for _, status, _, _ in records:
        if status is not None:
            status_counts[status] = status_counts.get(status, 0) + 1
    if status_counts:
        print("\nHTTP status distribution: " +
              ", ".join("%s=%d" % (code, count)
                        for code, count in sorted(status_counts.items())))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Concurrent load generator for the KVS HTTP server "
                     "(GitHub issue #135).")
    parser.add_argument("--host", default="192.168.10.2",
                         help="default matches the STM32 board's netconfig.tkb; "
                              "use 127.0.0.1 with --port matching qemu-kvs's "
                              "KVS_HOST_PORT for QEMU")
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--concurrency", type=int, default=4,
                         help="worker threads; the server has twenty-four TCP slots, "
                              "so values above twenty-four also exercise overload")
    parser.add_argument("--duration", type=float, default=30.0, help="seconds")
    parser.add_argument("--key-space", type=int, default=16,
                         help="distinct keys cycled through (default matches "
                              "TABLE_SLOTS=16, exercising collision/eviction "
                              "pressure)")
    parser.add_argument("--fixed-key", default="",
                         help="use one key for every operation; useful for "
                              "connection/transport stress without filling the "
                              "16-slot table")
    parser.add_argument("--value-size", type=int, default=64,
                         help="bytes, must be <= 128 (VAL_MAX)")
    parser.add_argument("--put-ratio", type=float, default=0.4)
    parser.add_argument("--get-ratio", type=float, default=0.4)
    parser.add_argument("--delete-ratio", type=float, default=0.1)
    parser.add_argument("--timeout", type=float, default=5.0,
                         help="per-request socket timeout, seconds")
    args = parser.parse_args()

    if not (0 < args.value_size <= 128):
        print("error: --value-size must be in 1..128 (VAL_MAX)", file=sys.stderr)
        return 1
    list_ratio = 1.0 - args.put_ratio - args.get_ratio - args.delete_ratio
    if list_ratio < 0:
        print("error: --put-ratio + --get-ratio + --delete-ratio exceeds 1.0",
              file=sys.stderr)
        return 1
    if args.concurrency < 1:
        print("error: --concurrency must be >= 1", file=sys.stderr)
        return 1

    metrics = Metrics()
    stop_event = threading.Event()
    threads = [
        threading.Thread(
            target=worker,
                  args=(stop_event, args.host, args.port, args.key_space,
                  args.put_ratio, args.get_ratio, args.delete_ratio,
                  args.value_size, args.timeout, args.fixed_key, metrics),
            daemon=True)
        for _ in range(args.concurrency)
    ]

    key_desc = "fixed-key=%s" % args.fixed_key if args.fixed_key else "key-space=%d" % args.key_space
    print("Starting %d worker thread(s) against http://%s:%d for %.0fs "
          "(mix: PUT=%.2f GET=%.2f DELETE=%.2f LIST=%.2f, %s, "
          "value-size=%dB)..." %
          (args.concurrency, args.host, args.port, args.duration,
           args.put_ratio, args.get_ratio, args.delete_ratio, list_ratio,
           key_desc, args.value_size))

    start = time.monotonic()
    for t in threads:
        t.start()
    time.sleep(args.duration)
    stop_event.set()
    for t in threads:
        t.join(timeout=args.timeout + 1)
    wall = time.monotonic() - start

    report(metrics.snapshot(), wall)
    return 0


if __name__ == "__main__":
    sys.exit(main())
