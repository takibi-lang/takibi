#!/usr/bin/env python3
"""Deterministic console-capture refusals; an exit-zero GDB error is not evidence."""

from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

import capture_kernel_console as collector
from pass_line import CaseCount, report_pass


def main():
    cases = CaseCount()
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary) / "console.log"
        for running in (True, False):
            for outcome in ("complete", "silent-error", "nonzero", "timeout"):
                cases.note()
                requests = []

                def qmp(port, command, arguments=None):
                    requests.append(command)
                    return {"running": running} if command == "query-status" else ""

                def gdb(argv, stdout, stderr, timeout):
                    if outcome == "timeout":
                        raise subprocess.TimeoutExpired(argv, timeout)
                    stdout.write("console snapshot complete\n" if outcome == "complete"
                                 else "Python Exception: missing symbol\n")
                    return SimpleNamespace(returncode=1 if outcome == "nonzero" else 0)

                with patch.object(collector, "qmp", qmp), \
                        patch.object(Path, "is_file", return_value=True), \
                        patch.object(Path, "is_socket", return_value=True), \
                        patch.object(collector.subprocess, "run", gdb):
                    collector.capture(1, "fixture.elf", output, "before-break")
                text = output.read_text()
                assert requests[-2] == "human-monitor-command", requests
                assert requests[-1] == ("cont" if running else "stop"), requests
                if outcome == "complete":
                    assert "console snapshot status: captured" in text, text
                else:
                    assert "console snapshot status: unavailable:" in text, text
                    assert "console snapshot status: captured" not in text, text
        cases.note()
        with patch.object(Path, "is_file", return_value=False), \
                patch.object(collector, "qmp") as monitor:
            collector.capture(1, "fixture.elf", output, "before-break")
        assert not monitor.called
        assert "missing compiler sidecar" in output.read_text()
    report_pass("capture-kernel-console controls",
                "completion required independently of GDB exit status; bounded failures restore prior run state",
                cases=cases.ran)


if __name__ == "__main__":
    main()
