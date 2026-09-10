#!/usr/bin/env python3
"""Controls for the shared host-side reachability wait.

The value of this helper is entirely in WHICH errors it waits out, so that is
what is planted here: an unreachable errno must be retried, and a timeout or
a refused connection must not be. Getting the second half wrong is the
dangerous direction -- it does not fail, it silently retries a request that
may already have arrived, and a test counting requests on the board then
passes while counting the wrong thing (GitHub issue #387).

No board and no socket: the attempt is a callable, so the failure modes can
be raised directly and exactly.
"""

import errno
import io
import contextlib
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from net_link_wait import wait_until_reachable

from pass_line import CaseCount, report_pass


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def failing(errors, then=object()):
    """A callable that raises each of `errors` in turn, then returns `then`."""
    CASES.note()
    queue = list(errors)

    def attempt():
        if queue:
            raise queue.pop(0)
        return then
    attempt.remaining = lambda: len(queue)
    return attempt


def unreachable(number):
    return OSError(number, "planted")


def main() -> int:
    # An unreachable address is waited out, and the caller gets its result.
    for name in ("EHOSTUNREACH", "ENETUNREACH"):
        number = getattr(errno, name)
        attempt = failing([unreachable(number)] * 3, then="answered")
        with contextlib.redirect_stdout(io.StringIO()) as noise:
            got = wait_until_reachable(attempt, seconds=5.0, poll=0.01)
        if got != "answered":
            print(f"FAIL net-link-wait control: {name} was not waited out")
            return 1
        if "waited" not in noise.getvalue():
            print(f"FAIL net-link-wait control: waiting for {name} was silent, "
                  "so a slow link leaves no trace in the log")
            return 1

    # A run that never had to wait says nothing, so the line means something.
    with contextlib.redirect_stdout(io.StringIO()) as quiet:
        wait_until_reachable(lambda: "answered", seconds=5.0, poll=0.01)
    if quiet.getvalue():
        print("FAIL net-link-wait control: a link that was ready already "
              f"still printed: {quiet.getvalue()!r}")
        return 1

    # The dangerous direction. Each of these can mean the request ARRIVED
    # and its answer was lost, so each must come straight back out.
    not_retried = [
        ("a timeout", socket.timeout("planted")),
        ("a refused connection", OSError(errno.ECONNREFUSED, "planted")),
        ("a reset connection", OSError(errno.ECONNRESET, "planted")),
        ("a broken pipe", OSError(errno.EPIPE, "planted")),
    ]
    for label, error in not_retried:
        attempt = failing([error], then="answered")
        try:
            wait_until_reachable(attempt, seconds=5.0, poll=0.01)
        except Exception as raised:
            if type(raised) is not type(error):
                print(f"FAIL net-link-wait control: {label} came back as "
                      f"{type(raised).__name__}, not itself")
                return 1
        else:
            print(f"FAIL net-link-wait control: {label} was RETRIED. A "
                  "request that may already have arrived was sent again, "
                  "which is how a counter check passes while counting the "
                  "wrong thing.")
            return 1
        if attempt.remaining() != 0:
            print(f"FAIL net-link-wait control: {label} did not even reach "
                  "the attempt")
            return 1

    # The deadline is real, and the caller sees the original error rather
    # than a summary of it.
    attempt = failing([unreachable(errno.EHOSTUNREACH)] * 10_000)
    started = time.monotonic()
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            wait_until_reachable(attempt, seconds=0.3, poll=0.01)
    except OSError as raised:
        if raised.errno != errno.EHOSTUNREACH:
            print("FAIL net-link-wait control: the expiring wait raised "
                  f"errno {raised.errno}, not the one it was waiting out")
            return 1
    else:
        print("FAIL net-link-wait control: an address that never became "
              "reachable returned successfully")
        return 1
    elapsed = time.monotonic() - started
    if not 0.2 <= elapsed <= 3.0:
        print(f"FAIL net-link-wait control: the 0.3s wait took {elapsed:.2f}s")
        return 1

    report_pass(
        "net-link-wait controls",
        "both unreachable errnos are waited out and reported, a ready "
        "link is silent, a timeout and three delivered-request errors "
        "come straight back, and the deadline expires with the original "
        "error",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
