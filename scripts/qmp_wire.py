"""The one place a QMP command reply is read (#879, #880).

QEMU may emit an asynchronous event (RESUME, STOP, ...) at any time,
including between a command and its reply. A client that takes the first line
after a command as the reply misreads an accepted command as a refusal: the
uart driver's postmortem BREAK did so in #871 repro run 2 and emptied the
walk. Every QMP client in scripts/ reads replies through qmp_reply;
scripts/check_qmp_reply_reads.py refuses a raw read after a command.
"""

import json
import time


def qmp_reply(stream, request_id=None, *, connection=None,
              deadline: float | None = None) -> dict:
    """The next QMP command reply on stream, skipping asynchronous events.

    With request_id, replies carrying a different "id" are skipped too. With
    connection and deadline, each read's socket timeout is the time left, and
    TimeoutError is raised once the deadline passes. Returns {} when the stream
    ends or a line is not a JSON object.
    """
    while True:
        if deadline is not None:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("QMP reply budget exhausted")
            if connection is not None:
                connection.settimeout(max(0.001, left))
        line = stream.readline(65536)
        if not line:
            return {}
        try:
            message = json.loads(line)
        except ValueError:
            return {}
        if not isinstance(message, dict):
            return {}
        if "event" in message:
            continue
        if request_id is not None and message.get("id") != request_id:
            continue
        return message
