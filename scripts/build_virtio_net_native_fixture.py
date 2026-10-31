#!/usr/bin/env python3
"""Copy the real virtio-net driver for a native, deterministic policy fixture.

Only the IRQ handler's AArch64 SEV builtin is replaced by a no-op provider:
AMD64 has no interrupt_notify lowering. The fixture never calls this handler;
clock and device-written RAM are controlled by the native support file. Every
submission, completion, timeout and queue-disable statement stays verbatim.

The occupancy import is dropped too: it reaches AArch64 kernel files, and the
driver needs only the MachineStopped name for DDB's look (#1164), which the
fixture never calls. The native support file declares that name.
"""
import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.source.read_text()
    anchor = "    interrupt_notify();"
    if source.count(anchor) != 1:
        raise SystemExit("virtio-net native fixture: expected exactly one IRQ notify anchor")
    occupancy = 'use "kernel/lib/occupancy.tkb";\n'
    if source.count(occupancy) != 1:
        raise SystemExit("virtio-net native fixture: expected exactly one occupancy import")
    source = source.replace(occupancy, "")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(source.replace(anchor, "    virtio_fixture_notify();"))


if __name__ == "__main__":
    main()
