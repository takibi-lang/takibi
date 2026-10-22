"""The Makefile's kernel compile flags, for scripts that compile kernel sources.

GitHub issue #781: the flags are defined once, as KERNEL_QEMU_COMPILE_FLAGS
and KERNEL_RPI5_COMPILE_FLAGS in the Makefile, and a script that compiles
kernel sources receives them through TAKIBI_KERNEL_COMPILE_FLAGS instead of
spelling its own list. An unset variable is an error, not a default, so a
script cannot silently compile with a stale flag set.
"""

import os
import shlex

ENV = "TAKIBI_KERNEL_COMPILE_FLAGS"


def kernel_compile_flags() -> list[str]:
    value = os.environ.get(ENV, "").strip()
    if not value:
        raise SystemExit(f"error: {ENV} is unset; run this through the Makefile "
                         "(it exports $(KERNEL_QEMU_COMPILE_FLAGS))")
    return shlex.split(value)
