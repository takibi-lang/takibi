#!/usr/bin/env python3
"""Controls for scripts/hooks/found-by-policy.sh's issue-closing trailers.

Both agents' PreToolUse hooks and .githooks/commit-msg call that one policy,
so these controls cover every path a closing commit can take.
"""

import subprocess
import tempfile
from pathlib import Path

from pass_line import report_pass


ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "scripts/hooks/found-by-policy.sh"


def message_status(message: str) -> int:
    with tempfile.NamedTemporaryFile("w", suffix=".msg") as handle:
        handle.write(message)
        handle.flush()
        return subprocess.run(
            ["bash", str(POLICY), "--commit-message-file", handle.name],
            capture_output=True, check=False).returncode


def command_status(command: str) -> int:
    return subprocess.run(["bash", str(POLICY), "--command", command],
                          capture_output=True, check=False).returncode


def main() -> int:
    controls = []
    head = "fix the thing\n\nCloses #1.\n\nFound-by: test\n"
    cases = [
        ("no, closing", head + "Protocol: no\n", 0),
        ("yes with property", head + "Protocol: yes -- a taken value survives\n", 0),
        ("missing", head, 10),
        ("yes without property", head + "Protocol: yes\n", 10),
        ("unknown value", head + "Protocol: maybe\n", 10),
        ("not a line of its own", head + "see Protocol: no\n", 10),
        ("non-closing commit", "tidy\n\nFound-by: review\n", 0),
    ]
    for name, message, want in cases:
        got = message_status(message)
        assert got == want, f"message {name}: {got} != {want}"
        controls.append(name)
    commands = [
        ("command no", "git commit -m 'x\n\nCloses #1.\n\nFound-by: test\nProtocol: no'", 0),
        ("command missing", "git commit -m 'x\n\nCloses #1.\n\nFound-by: test'", 10),
        ("command bare yes", "git commit -m 'x\n\nCloses #1.\n\nFound-by: test\nProtocol: yes'", 10),
    ]
    for name, command, want in commands:
        got = command_status(command)
        assert got == want, f"{name}: {got} != {want}"
        controls.append(name)
    report_pass("found-by-policy",
                "issue-closing commits need Found-by and Protocol trailers",
                controls=len(controls))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
