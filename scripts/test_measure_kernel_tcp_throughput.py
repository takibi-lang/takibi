#!/usr/bin/env python3
"""Controls for the wire-throughput measurement, with a scripted curl.

The measurement itself needs a board serving HTTP, so the part that can be
controlled offline is the part that decides what the numbers MEAN: that a
transfer of zero bytes or zero seconds is refused rather than divided by, that
transfers returning different sizes are not averaged into one figure, and that
the artifact records what was actually measured.

That distinction is the reason this exists. A throughput tool that divides by
a zero it was handed reports an infinity or a crash where it should report
that it measured nothing -- the shape GitHub issue #513 is about, arriving in
a tool whose whole output is a number.

`curl` is replaced on PATH rather than mocked in-process, so the real argument
construction and output parsing run.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "scripts" / "measure_kernel_tcp_throughput.py"

FAKE_CURL = """#!/usr/bin/env python3
import os, sys
# The tool asks for "%{size_download} %{time_total}"; answer per invocation.
script = os.environ["FAKE_CURL_SCRIPT"].split(";")
state = os.environ["FAKE_CURL_STATE"]
try:
    index = int(open(state).read())
except OSError:
    index = 0
open(state, "w").write(str(index + 1))
reply = script[min(index, len(script) - 1)]
if reply == "fail":
    sys.stderr.write("curl: (7) refused\\n")
    sys.exit(7)
sys.stdout.write(reply)
"""


def run(script, extra=()):
    with tempfile.TemporaryDirectory() as name:
        directory = Path(name)
        curl = directory / "curl"
        curl.write_text(FAKE_CURL, encoding="ascii")
        curl.chmod(0o755)
        environment = dict(os.environ)
        environment["PATH"] = f"{directory}:{environment['PATH']}"
        environment["FAKE_CURL_SCRIPT"] = script
        environment["FAKE_CURL_STATE"] = str(directory / "state")
        artifact = directory / "out.json"
        result = subprocess.run(
            [sys.executable, str(TOOL), "--host", "10.0.0.1",
             "--json", str(artifact), *extra],
            capture_output=True, text=True, env=environment)
        body = artifact.read_text() if artifact.exists() else ""
        return result.returncode, result.stdout + result.stderr, body


def expect(label, script, ok, needle, extra=()):
    status, output, _ = run(script, extra)
    if (status == 0) != ok:
        print(f"FAIL tcp-throughput control: {label} exited {status}, "
              f"expected {'0' if ok else 'nonzero'}\n{output}")
        return False
    if needle not in output:
        print(f"FAIL tcp-throughput control: {label} did not report "
              f"{needle!r}\n{output}")
        return False
    return True


def main() -> int:
    cases = [
        ("a healthy transfer", "1048576 1.0", True, "1024-1024 KiB/s",
         ("--repeat", "1")),
        # The two ways a number can be reported about nothing.
        ("zero bytes", "0 1.0", False, "which measures nothing",
         ("--repeat", "1")),
        ("zero seconds", "1048576 0", False, "which measures nothing",
         ("--repeat", "1")),
        # Different sizes are different measurements, not one average.
        ("transfers of differing size", "1048576 1.0;524288 1.0", False,
         "not the same measurement", ("--repeat", "2")),
        ("a transfer that never completes", "fail", False,
         "did not transfer", ("--repeat", "1")),
        # The spread across repeats is the point of repeating.
        ("a spread across repeats", "1048576 1.0;1048576 2.0", True,
         "512-1024 KiB/s", ("--repeat", "2")),
    ]
    for label, script, ok, needle, extra in cases:
        if not expect(label, script, ok, needle, extra):
            return 1

    # The artifact records what was measured, not a summary of it.
    status, output, body = run("1048576 1.0", ("--repeat", "1",
                                               "--commit", "deadbeef"))
    if status != 0:
        print(f"FAIL tcp-throughput control: the artifact case failed\n{output}")
        return 1
    for token in ('"bytes": 1048576', '"commit": "deadbeef"', '"runs"'):
        if token not in body:
            print(f"FAIL tcp-throughput control: the artifact lacks {token!r}"
                  f"\n{body}")
            return 1

    print("PASS tcp-throughput controls: a healthy transfer reports its rate "
          "and a spread, zero bytes and zero seconds are refused as measuring "
          "nothing, transfers of differing size are not averaged, a refused "
          "connection is reported, and the artifact records bytes, commit and "
          "per-run figures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
