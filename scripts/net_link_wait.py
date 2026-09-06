#!/usr/bin/env python3
"""One answer to "can this host reach the board yet", for host-stack tests.

The hardware net runners start a board and run a test script with nothing in
between, so the first request races the board's boot and its PHY
auto-negotiation. The raw AF_PACKET tests survive that by resending every
frame. The tests that go through the host kernel's own TCP/IP stack -- which
is the entire point of those tests -- get one attempt, and that is where the
flakiness landed (GitHub issue #387).

WHICH ERRORS ARE WAITED OUT IS THE WHOLE CORRECTNESS ARGUMENT, and it is the
part that must not be re-derived per script:

  EHOSTUNREACH and ENETUNREACH are raised LOCALLY, by the host's neighbour
  subsystem, when nothing could be put on the wire. The board cannot have
  seen the request, so no counter on it can have moved, and retrying is
  free of consequence.

  A timeout or a refused connection is NOT retried. Either can mean the
  request ARRIVED and its response was lost, so retrying through one
  silently breaks any test that checks a request counter -- and two of the
  callers here do exactly that.

That distinction is why this is a shared function rather than a copied loop.
Of three network-test flakes in this tree, one was the stack and two were the
harness assuming a readiness it had not established; a helper that gets the
distinction right once beats four scripts that each have to.

This answers the HOST's question. The board's own readiness is a different
question with a better answer: the kernel says when its link is up, and
`scripts/run_hwtest_net_ram.sh` and `scripts/run_kernel_hwtest_rpi5.sh` wait
for that line before starting any wire test. Use both -- the boot-log gate
means a board that never came up is reported as such rather than as a
protocol defect, and this means a host path that is still resolving does not
fail a test that was going to pass.
"""

from __future__ import annotations

import errno
import time

# Locally generated: nothing reached the wire, so nothing on the board moved.
UNREACHABLE = (errno.EHOSTUNREACH, errno.ENETUNREACH)

DEFAULT_WAIT_SECS = 20.0
DEFAULT_POLL_SECS = 0.25


def wait_until_reachable(attempt, seconds: float = DEFAULT_WAIT_SECS,
                         poll: float = DEFAULT_POLL_SECS, label: str = ""):
    """Call `attempt` until it succeeds, retrying ONLY while unreachable.

    Returns whatever `attempt` returns. Any error that is not one of
    UNREACHABLE propagates immediately, and so does an unreachable one once
    `seconds` have passed -- the caller sees the real error either way,
    rather than a wrapper's summary of it.

    Prints how long it waited, but only when it actually waited: a line on
    every healthy run would be noise, and its absence is the signal that the
    board was ready when the test started.
    """
    deadline = time.monotonic() + seconds
    started = time.monotonic()
    waited = False
    while True:
        try:
            result = attempt()
        except OSError as error:
            if error.errno not in UNREACHABLE:
                raise
            if time.monotonic() >= deadline:
                raise
            waited = True
            time.sleep(poll)
            continue
        if waited:
            print("  (waited %.1fs for the board's link%s)"
                  % (time.monotonic() - started, f": {label}" if label else ""))
        return result
