#!/usr/bin/env python3
"""Exercise the RPi5 shell smoke's real HTTP and fresh-ps verdict flow."""

from email.message import Message
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
from unittest.mock import patch

from pass_line import CaseCount, report_pass
import run_kernel_shell_rpi5_smoketest as driver

CASES = CaseCount()


class Response:
    def __init__(self, status=200, content_type="text/html", body=None):
        self.status = status
        self.headers = Message()
        self.headers["Content-Type"] = content_type
        self.body = driver.BODY_MARKER if body is None else body

    def read(self, length):
        return self.body[:length]

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass


class Session:
    def __init__(self, ready=True, workers=1, echoed_only=False, silent=False, root=b"."):
        self.text = ((driver.LISTENER + b"\n" + driver.SHELL + b"\n # ")
                     if ready else driver.SHELL + b"\n # ")
        self.workers, self.echoed_only, self.silent = workers, echoed_only, silent
        self.root = root
        self.sent = []

    def normalized(self):
        return self.text

    def send(self, command):
        self.sent.append(command)
        if self.silent:
            return
        self.text += command
        if not self.echoed_only:
            # Independent transcript shape from the physical shell run. Do
            # not construct the fixture from the matcher it is meant to test.
            self.text += b"\n" + (b"    2 0         0:00 /bin/httpd -f -p 8080 -h "
                                  + self.root + b"\n") * self.workers
            self.text += driver.PS_DONE + b"\n # "

    def wait_for(self, predicate, _seconds, watch_from=None):
        return predicate(self.text) or None


def case(*, response=None, expected=None, **options):
    CASES.note()
    session, phases, calls = Session(**options), [], []

    class Opener:
        def open(self, url, timeout):
            calls.append((url, timeout))
            return response or Response()

    with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
        directory = Path(temporary)
        with patch.object(driver.urllib.request, "build_opener", return_value=Opener()), contextlib.redirect_stdout(io.StringIO()):
            try:
                driver.run(session, directory, "http://board/", phases.append)
            except RuntimeError as error:
                assert expected is not None and expected in str(error), (expected, error)
            else:
                assert expected is None, expected
                assert calls == [("http://board/", 15)] * 2
                assert len(session.sent) == 2
                assert phases == ["shell-and-listener", "http-1", "processes-after-http-1",
                                  "http-2", "processes-after-http-2"]
                assert all((directory / f"http-{number}.body").exists() for number in (1, 2))
                assert all((directory / f"ps-{number}.log").exists() for number in (1, 2))
        timing = [json.loads(line) for path in directory.glob("await-*.jsonl")
                  for line in path.read_text().splitlines()]
        assert timing and all(row["timeout_seconds"] in (180, 20) for row in timing)
        if expected and (not options.get("ready", True) or options.get("silent")
                         or options.get("echoed_only")):
            assert any(row["await"] == phases[-1] and row["status"] == "not-arrived"
                       for row in timing)
        if not options.get("ready", True):
            assert not calls and not session.sent


def main():
    case()
    case(root=b"/")
    case(ready=False, expected="shell-and-listener")
    case(silent=True, expected="processes-after-http-1")
    case(echoed_only=True, expected="processes-after-http-1")
    case(workers=0, expected="ps showed 0")
    case(workers=2, expected="ps showed 2")
    case(response=Response(status=404), expected="returned 404")
    case(response=Response(content_type="application/octet-stream"), expected="text/html")
    case(response=Response(body=b"wrong index"), expected="bounded index body")
    case(response=Response(body=driver.BODY_MARKER + b"x" * 65536), expected="bounded index body")
    report_pass("rpi5 shell smoke controls",
                "two HTTP responses and fresh process snapshots pass; missing readiness, "
                "echoes, silence, workers and invalid HTTP responses fail", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
