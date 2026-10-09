#!/usr/bin/env python3
"""Generate a test-only virtio-blk MMIO overlay; never copy ownership logic."""
import os
from pathlib import Path
import shutil
import sys


def replace_once(path, before, after):
    text = path.read_text(encoding="ascii")
    if text.count(before) != 1:
        raise SystemExit(f"DMA fixture anchor must occur once in {path}: {before!r}")
    path.write_text(text.replace(before, after), encoding="ascii")


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: build_qemu_dma_fixture.py ROOT OVERLAY [CONTROL]")
    root, overlay = (Path(arg).resolve() for arg in sys.argv[1:3])
    control = sys.argv[3] if len(sys.argv) == 4 else None
    if control not in (None, "error", "reset", "failed", "disabled"):
        raise SystemExit("unknown DMA control")
    kernel = overlay / "kernel"
    if kernel.exists():
        shutil.rmtree(kernel)
    changed = {"platform/qemu/init.tkb", "drivers/block/virtio_blk.tkb",
               "drivers/block/virtio_blk_dma.tkb"}
    for current, directories, files in os.walk(root / "kernel"):
        directories[:] = [name for name in directories if name != "build"]
        relative = Path(current).relative_to(root / "kernel")
        target = kernel / relative
        target.mkdir(parents=True, exist_ok=True)
        for name in files:
            source = Path(current) / name
            if (relative / name).as_posix() in changed:
                shutil.copyfile(source, target / name)
            else:
                (target / name).symlink_to(source)
    init = kernel / "platform/qemu/init.tkb"
    replace_once(init, "fn main() !{unsafe} {", "fn production_main() !{unsafe} {")
    init.write_text('use "kernel/tests/qemu/dma/virtio_blk_fixture.tkb";\n' +
                    init.read_text(encoding="ascii") +
                    '\nfn main() !{unsafe} { dma_fixture_run(); }\n',
                    encoding="ascii")
    driver = kernel / "drivers/block/virtio_blk.tkb"
    replace_once(driver,
                 "return unsafe { (virtio_blk_base + offset) as *io i32 };",
                 "return unsafe { ((dma_fixture_registers as *i32) + "
                 "((offset / 4) as isize)) as *io i32 };")
    replace_once(driver, "    *(virtio_blk_reg(VIRTIO_BLK_QUEUE_NOTIFY)) = 0;",
                 "    *(virtio_blk_reg(VIRTIO_BLK_QUEUE_NOTIFY)) = 0;\n"
                 "    dma_fixture_notify();")
    mint = kernel / "drivers/block/virtio_blk_dma.tkb"
    replace_once(mint, "    *(virtio_blk_reg(VIRTIO_BLK_STATUS)) = 0;",
                 "    if (dma_fixture_mode != 2) {\n"
                 "        *(virtio_blk_reg(VIRTIO_BLK_STATUS)) = 0;\n"
                 "    }")

    # Each control changes an actual maintained branch, independently of the
    # mock device. The unmodified fixture must reject its resulting authority.
    if control == "error":
        replace_once(mint, "    virtio_blk_request_settle();\n"
                     "    virtio_blk_data_settle();\n"
                     "    return VirtioBlkReceiveUsed::Observed;",
                     "    virtio_blk_data_settle();\n"
                     "    return VirtioBlkReceiveUsed::Observed;")
    elif control == "reset":
        replace_once(mint, "    virtio_blk_request_settle();\n"
                     "    virtio_blk_data_settle();\n    return true;",
                     "    virtio_blk_request_settle();\n    return true;")
    elif control == "failed":
        replace_once(mint, "        virtio_blk_disabled = true;\n        return false;",
                     "        virtio_blk_disabled = true;\n        return true;")
    elif control == "disabled":
        replace_once(driver, "    if (virtio_blk_init() == false) { return false; }",
                     "    if (virtio_blk_init() == false) { return true; }")


if __name__ == "__main__":
    main()
