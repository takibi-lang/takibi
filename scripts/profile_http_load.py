#!/usr/bin/env python3
"""
Fires repeated HTTP requests at examples/http_server/http_server.tkb so
profile_http_server.py's PC sampler has something busy to sample.
Imports http_server_test.do_request rather than reimplementing the
TCP/HTTP framing -- http_server_test.py itself only ever sends 2 requests
total (enough for its own correctness check, not enough to profile; see
its module docstring), so this script just calls the same helper in a
loop with fresh client ports/ISNs/expected counters each time.

Run as: python3 profile_http_load.py NUM_REQUESTS

Note each do_request() call takes >= 1 second even on success: its last
step (expect_silence) deliberately waits out the full SILENCE_TIMEOUT_SECS
to confirm the server didn't send anything after closing. That's
appropriate for a correctness test; for pure load generation it's dead
time, but reusing do_request as-is (rather than forking a trimmed copy of
the TCP/HTTP framing logic) was judged the better tradeoff for a one-off
profiling tool -- see profile_http_server.py for how NUM_REQUESTS and the
sampler's sample count are chosen to roughly overlap despite this.

A validation failure inside do_request doesn't stop the loop and doesn't
mean the server skipped doing the work: the request/response/close cycle
still ran over the wire regardless of what this script's client-side
verification concludes (see do_request's docstring in http_server_test.py).
Failures are just counted and reported, since this script's only job is to
generate load, not to verify correctness (http_server_test.py already does
that, and runs as part of `make qemutest`).
"""
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import http_server_test as hst  # noqa: E402


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: profile_http_load.py NUM_REQUESTS", file=sys.stderr)
        return 1
    num_requests = int(sys.argv[1])

    ok_count = 0
    for i in range(num_requests):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind((hst.QEMU_HOST, hst.LOCAL_PORT))
        try:
            ok = hst.do_request(sock, client_port=51000 + i, client_isn=10000 + i * 1000,
                                 expected_count=i + 1)
        finally:
            sock.close()
        if ok:
            ok_count += 1

    print("PROFILE_LOAD: %d/%d requests completed and verified" % (ok_count, num_requests),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
