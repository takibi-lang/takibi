"""Bound a gdb `continue` from inside a gdb Python check.

The kernel checks under scripts/ that run inside gdb-multiarch stop a
`continue` that has waited long enough by sending gdb a SIGINT from a timer
thread. A single SIGINT can be lost: one that lands before gdb is waiting on
the target does not stop it, and the `continue` then waits for good. In a
loaded allcheck, the uart-wake lane's scalar control sat in exactly that
state for six minutes until it was killed by hand.

interrupt_after() therefore repeats the SIGINT every RETRY_SECONDS until the
caller cancels it, which it does as soon as `continue` returns. The object
it returns has cancel(), like the threading.Timer the checks used before.
"""

import os
import signal
import threading

RETRY_SECONDS = 2.0


class RepeatingInterrupt:
    def __init__(self, seconds: float) -> None:
        self._returned = threading.Event()
        threading.Thread(target=self._fire, args=(seconds,),
                         daemon=True).start()

    def _fire(self, seconds: float) -> None:
        if self._returned.wait(seconds):
            return
        while not self._returned.is_set():
            os.kill(os.getpid(), signal.SIGINT)
            self._returned.wait(RETRY_SECONDS)

    def cancel(self) -> None:
        self._returned.set()


def interrupt_after(seconds: float) -> RepeatingInterrupt:
    return RepeatingInterrupt(seconds)
