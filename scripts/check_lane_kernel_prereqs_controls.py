#!/usr/bin/env python3
"""Controls for check_lane_kernel_prereqs.py (#645's land failure)."""

from check_lane_kernel_prereqs import MAKEFILE, problems
from pass_line import CaseCount, report_pass


def main() -> int:
    cases = CaseCount()
    text = MAKEFILE.read_text(encoding="ascii")
    assert not problems(text), problems(text)
    failing = {
        # The #645 shape.
        "lane on a kernel object": ".PHONY: zzcheck\nzzcheck: $(KERNEL_RPI5_MAIN_O)\n\ttrue\n",
        "continued prerequisite line": ".PHONY: zzcheck\nzzcheck: build \\\n\t$(KERNEL_SHELL_EXT2_IMAGE)\n\ttrue\n",
        "literal build path": ".PHONY: zzcheck\nzzcheck: kernel/build/rpi5/main.o\n\ttrue\n",
    }
    for name, rule in failing.items():
        cases.note()
        assert problems(text + "\n" + rule), name
    passing = {
        "private inner target": ".PHONY: _zzbuild\n_zzbuild: $(KERNEL_RPI5_MAIN_O)\n",
        "file rule": "zz.o: $(KERNEL_RPI5_MAIN_O)\n\ttrue\n",
        "order-only prerequisite": ".PHONY: zzcheck\nzzcheck: build | $(KERNEL_BUILD_DIR)\n\ttrue\n",
    }
    for name, rule in passing.items():
        cases.note()
        assert not problems(text + "\n" + rule), name
    cases.note()
    assert not problems(text + "\n" + failing["lane on a kernel object"],
                        {"zzcheck": "reviewed"}), "reviewed"
    report_pass("lane-kernel-prereqs controls",
                f"production passes and {cases.ran} racing, private, file-rule "
                "and reviewed shapes behave as specified", controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
