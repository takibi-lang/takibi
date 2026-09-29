#!/usr/bin/env python3
"""Fast negative controls for the live/offline RPi5 DDB capture predicates.

No terminal or board is opened: the maintained synthetic board's reply bytes
feed the same validator used after a physical run. Timing/retry controls stay
in slowcheck_run_kernel_ddb_rpi5_driver.py.
"""

import importlib.util
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Evidence:
    resume_attempts = 1

    @staticmethod
    def bail(message):
        return SystemExit(message)


def main():
    driver = load("run_kernel_ddb_rpi5_driver")
    fixture = load("slowcheck_run_kernel_ddb_rpi5_driver")
    prefix = fixture.BANNER_HEAD + fixture.PEER_PENDING + fixture.BANNER_TAIL
    for command in (b"xkfault", b"events", b"bt", b"bt cpu 1", b"wait"):
        prefix += fixture.PROMPT + fixture.REPLIES[command]
    continuing = (b"\nddb: continuing\n"
                  b"ddb: console tx=queued\n")
    healthy = prefix + continuing + fixture.PEER_RECORD + fixture.RESUME_ECHO
    marker = fixture.PEER_RECORD
    cases = (
        ("CRLF record", healthy, None),
        ("LF record", healthy.replace(b"\r", b""), None),
        ("all CRLF", healthy.replace(b"\r", b"").replace(b"\n", b"\r\n"), None),
        ("missing delivery", healthy.replace(marker, b""), "record did not follow"),
        ("delivery before continue", prefix + marker + continuing + fixture.RESUME_ECHO,
         "record did not follow"),
        ("duplicated delivery", prefix + continuing + marker + marker + fixture.RESUME_ECHO,
         "record did not follow"),
        ("delivery before and after", prefix + marker + continuing + marker + fixture.RESUME_ECHO,
         "record did not follow"),
        ("echoed command only", healthy.replace(fixture.RESUME_ECHO, b"echo ddb-resume-ok\r\n"),
         "workload did not resume"),
        ("output before continue", fixture.RESUME_ECHO + healthy.replace(fixture.RESUME_ECHO, b""),
         "workload did not resume"),
        ("missing peer root", healthy.replace(fixture.REPLIES[b"bt cpu 1"], b""),
         "backtrace the stopped peer"),
        ("partial world stop", healthy.replace(b"mask=0x000000000000000e", b"mask=0x0000000000000002"),
         "stop and acknowledge all online peers"),
    )
    count = CaseCount()
    for name, capture, expected in cases:
        count.note()
        try:
            driver.validate_capture(capture, capture.count(fixture.PROMPT), Evidence())
        except SystemExit as error:
            if expected is None or expected not in str(error):
                raise SystemExit(f"FAIL ddb-rpi5 capture control {name}: {error}")
        else:
            if expected is not None:
                raise SystemExit(f"FAIL ddb-rpi5 capture control {name}: accepted invalid evidence")
    software = load("run_kernel_ddb_rpi5_software_driver")
    continued = b"ddb: continuing\n"
    for capture, expected in (
        (continued + b"\nddb-software-resume-ok\n/ # ", True),
        (continued + b"\nddb-software-resume-ok\r\n # \x1b[6n", True),
        (continued + b" # echo ddb-software-resume-ok\n # ", False),
        (b"\nddb-software-resume-ok\n # \n" + continued, False),
        (continued + b"\nddb-software-resume-ok\n", False),
        (b"\nddb-software-resume-ok\n # ", False),
    ):
        count.note()
        if software.shell_resumed(capture) != expected:
            raise SystemExit("FAIL software DDB capture control: prompt or output ordering")
    report_pass("ddb-rpi5 capture controls", "LF/CRLF pass; early, duplicate and missing delivery, echoed commands and invalid stopped-world evidence fail",
                cases=count.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
