#!/usr/bin/env python3
"""Expected-fail signal conformance rows differ from host Linux (#999).

Usage: check_signal_xfail_rows.py HOST_OUTPUT VIEW_EXPECTED

HOST_OUTPUT is what user_payload's `signal_xfail_probe_alone` printed under
qemu-aarch64 on the host; VIEW_EXPECTED is the linux_file view, which holds
the kernel's present answer for each row. Each row is a line
`userspace signal xfail #N: TEXT`. The check refuses:

1. a host output with no rows, or a row the view does not have, or a view row
   the host did not print (the two sets of issues must be equal);
2. a row whose view text equals the host's: the kernel line then claims
   Linux's behaviour, so the row is a conformance row, not an expected
   failure -- move it out when its issue closes.

The kernel side of "the lane fails if a row unexpectedly passes" is the view
itself: a kernel that starts answering as Linux does prints the host's text,
which is not the view's.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROW = re.compile(r"^userspace signal xfail (#\d+): (.+)$")


def rows(text: str) -> dict[str, str]:
    found = {}
    for line in text.splitlines():
        match = ROW.match(line)
        if match:
            if match[1] in found:
                raise ValueError(f"row {match[1]} appears twice")
            found[match[1]] = match[2]
    return found


def problems(host_text: str, view_text: str) -> list[str]:
    try:
        host, view = rows(host_text), rows(view_text)
    except ValueError as error:
        return [str(error)]
    if not host:
        return ["host Linux printed no expected-fail row"]
    failures = []
    for issue in sorted(set(host) ^ set(view)):
        where = "the view" if issue in host else "the host output"
        failures.append(f"row {issue} is missing from {where}")
    for issue in sorted(set(host) & set(view)):
        if host[issue] == view[issue]:
            failures.append(f"row {issue}: the kernel's line is Linux's "
                            f"({host[issue]!r}); it is no longer an expected "
                            "failure")
    return failures


def controls() -> list[str]:
    """Each refusal on a planted pair, so the check is not vacuous."""
    host = ("userspace signal xfail #1: linux\n"
            "userspace signal xfail #2: linux too\n")
    view = ("userspace signal xfail #1: kernel\n"
            "userspace signal xfail #2: kernel too\n")
    failed = []
    if problems(host, view):
        failed.append("a differing pair was refused")
    for label, h, v in (
            ("an empty host output", "", view),
            ("a row missing from the view", host,
             "userspace signal xfail #1: kernel\n"),
            ("a row the kernel now passes", host,
             "userspace signal xfail #1: linux\n"
             "userspace signal xfail #2: kernel too\n"),
            ("a duplicated row", host + "userspace signal xfail #1: again\n",
             view)):
        if not problems(h, v):
            failed.append(f"{label} was accepted")
    return failed


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    host_text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    view_text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
    failures = [f"control: {c}" for c in controls()]
    failures += problems(host_text, view_text)
    for failure in failures:
        print(f"FAIL signal-xfail-rows: {failure}")
    if failures:
        return 1
    report_pass("signal-xfail-rows",
                f"{len(rows(host_text))} expected-fail rows answer otherwise "
                "on host Linux than in the kernel's linux_file view; the "
                "planted pass, gap and duplicate are refused",
                rows=len(rows(host_text)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
