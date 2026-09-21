#!/usr/bin/env python3
"""Keep ash's /bin listing in step with the rootfs image recipe."""

from pathlib import Path
import re

from pass_line import report_pass


ROOT = Path(__file__).resolve().parent.parent
BIN_COMMAND = "/bin/ls /bin"
FIRST_COMMANDS = (
    "x=; /bin/ls",
    "/bin/ls -a",
    BIN_COMMAND,
    "/bin/ls /many",
)


def image_bin_names(makefile: str) -> list[str]:
    start = makefile.index("$(KERNEL_EXT2_IMAGE):")
    end = makefile.index("$(KERNEL_SHELL_EXT2_IMAGE):", start)
    names = []
    for line in makefile[start:end].splitlines():
        if "e2cp " in line and ":/bin/" in line:
            match = re.search(r"\.tmp:/bin/([\w.-]+)(?:\s|$)", line)
        elif "link " in line and re.search(r"link .* /bin/", line):
            match = re.search(r"\blink /bin/[\w.-]+ /bin/([\w.-]+)'", line)
        else:
            continue
        if match is None:
            raise ValueError(f"unrecognized /bin image command: {line.strip()}")
        names.append(match.group(1))
    if not names or len(names) != len(set(names)):
        raise ValueError("/bin image names are empty or duplicated")
    return sorted(names)


def expected_bin_names(stdin: str, expected: str) -> list[str]:
    commands = tuple(line for line in stdin.splitlines()
                     if line and not line.startswith("#"))
    if commands[:4] != FIRST_COMMANDS:
        raise ValueError("ash's initial ls commands changed; update this check")
    lines = expected.splitlines()
    try:
        root_end = lines.index(".")
        root = lines[:root_end]
        bin_start = 2 * root_end + 2
        if lines[root_end:bin_start] != [".", "..", *root]:
            raise ValueError("ash's two root listings no longer agree")
        bin_end = lines.index("entry-00", bin_start)
    except ValueError as error:
        raise ValueError("ash listing boundaries changed") from error
    return lines[bin_start:bin_end]


def main() -> int:
    makefile = (ROOT / "Makefile").read_text(encoding="ascii")
    stdin = (ROOT / "kernel/tests/common/ash/ash.stdin").read_text(
        encoding="ascii")
    expected = (ROOT / "kernel/tests/common/ash/ash.expected").read_text(
        encoding="ascii")
    try:
        actual = image_bin_names(makefile)
        listed = expected_bin_names(stdin, expected)
    except ValueError as error:
        print(f"FAIL ash-bin-inventory: {error}")
        return 1
    if actual != listed:
        missing = sorted(set(actual) - set(listed))
        stale = sorted(set(listed) - set(actual))
        print("FAIL ash-bin-inventory: /bin listing differs from image recipe; "
              f"missing={missing} stale={stale}")
        return 1
    report_pass("ash-bin-inventory",
                f"ash lists all {len(actual)} /bin image entries in order",
                entries=len(actual))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
