#!/usr/bin/env python3
"""Replace only the QEMU main body for the isolated invariant-stop fixture."""

import os
from pathlib import Path
import shutil
import sys

from build_qemu_dma_fixture import replace_once


def main():
    root, overlay = (Path(arg).resolve() for arg in sys.argv[1:])
    kernel = overlay / "kernel"
    if kernel.exists():
        shutil.rmtree(kernel)
    for current, directories, files in os.walk(root / "kernel"):
        directories[:] = [name for name in directories if name != "build"]
        relative = Path(current).relative_to(root / "kernel")
        target = kernel / relative
        target.mkdir(parents=True, exist_ok=True)
        for name in files:
            source = Path(current) / name
            if (relative / name).as_posix() == "platform/qemu/init.tkb":
                shutil.copyfile(source, target / name)
            else:
                (target / name).symlink_to(source)
    init = kernel / "platform/qemu/init.tkb"
    replace_once(init, "fn main() !{unsafe} {", "fn production_main() !{unsafe} {")
    init.write_text('use "kernel/tests/qemu/invariant_stop/fixture.tkb";\n' +
                    init.read_text(encoding="ascii") +
                    '\nfn main() { invariant_stop_fixture_run(); }\n', encoding="ascii")


if __name__ == "__main__":
    main()
