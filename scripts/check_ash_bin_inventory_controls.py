#!/usr/bin/env python3
"""Positive and failure-specific controls for the ash /bin inventory check."""

from pathlib import Path

import check_ash_bin_inventory as check
from pass_line import report_pass


ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    controls = []
    makefile = (ROOT / "Makefile").read_text(encoding="ascii")
    stdin = (ROOT / "kernel/tests/common/ash/ash.stdin").read_text(
        encoding="ascii")
    expected = (ROOT / "kernel/tests/common/ash/ash.expected").read_text(
        encoding="ascii")
    names = check.image_bin_names(makefile)
    assert names == check.expected_bin_names(stdin, expected)
    controls.append("current tree")
    injected = makefile.replace(
        "$(KERNEL_SHELL_EXT2_IMAGE):",
        "\tE2FSPROGS_FAKE_TIME=1700000000 e2cp fixture "
        "$@.tmp:/bin/new-fixture\n\n$(KERNEL_SHELL_EXT2_IMAGE):", 1)
    assert "new-fixture" in check.image_bin_names(injected)
    assert check.image_bin_names(injected) != check.expected_bin_names(
        stdin, expected)
    controls.append("added image entry")
    removed = expected.replace("peer-spin\n", "", 1)
    assert names != check.expected_bin_names(stdin, removed)
    controls.append("missing expected entry")
    try:
        check.image_bin_names(makefile.replace(
            "$@.tmp:/bin/peer-spin", "$@.tmp:/bin/peer-spin.extra-syntax", 1))
    except ValueError:
        # A valid new name is not an unsupported command, so test a malformed
        # path spelling instead below.
        raise AssertionError("valid image name was refused")
    malformed = makefile.replace("$@.tmp:/bin/peer-spin",
                                 "$@.tmp:/bin/peer-spin/child", 1)
    try:
        check.image_bin_names(malformed)
    except ValueError:
        pass
    else:
        raise AssertionError("unrecognized /bin recipe syntax was accepted")
    controls.append("unrecognized recipe")
    report_pass("ash-bin-inventory controls",
                "current inventory passes; additions, omissions, and "
                "unrecognized image commands are refused",
                controls=len(controls))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
