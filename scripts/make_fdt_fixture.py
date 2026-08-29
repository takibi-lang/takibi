#!/usr/bin/env python3
"""Build the device-tree blob linux_user/fdt tests kernel/boot/fdt.tkb against.

Synthetic, and deliberately shaped like the real thing. Every number here
was read out of the pinned Raspberry Pi firmware DTB for the Pi 5
(raspberrypi/firmware, boot/bcm2712-rpi-5-b.dtb), which is the blob that
board's firmware actually hands this kernel:

    /                        #address-cells = <2>  #size-cells = <2>
    /soc@107c000000          #address-cells = <1>  #size-cells = <1>
                             ranges = <0x0 0x10 0x0 0x80000000>
    /soc@.../timer@7c003000  compatible = "brcm,bcm2835-system-timer"
                             reg = <0x7c003000 0x1000>
                             clock-frequency = <1000000>
    /timer                   compatible = "arm,armv8-timer"   (no frequency)

Generated rather than committed because the real blob is built from the
Linux kernel's device tree source and this repository does not carry other
projects' GPL binaries -- it downloads BusyBox and musl for the same reason.
What is pinned here instead are the values, and the shape that makes the
address translation nontrivial: the timer's own `reg` is a bus address, and
only the parent's `ranges` says where that bus is in physical memory.

The `/timer` node is not decoration. It is the ARM generic timer, it is the
node a reader looking for "a timer" would find first, and it carries no
frequency at all -- which is the whole reason the SoC counter is being
looked for. A scanner that matched it would pass a test that omitted it.
"""
import struct
import sys

FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_END = 9


class Builder:
    def __init__(self):
        self.struct = bytearray()
        self.strings = bytearray()
        self.offsets = {}

    def string(self, name):
        if name not in self.offsets:
            self.offsets[name] = len(self.strings)
            self.strings += name.encode("ascii") + b"\0"
        return self.offsets[name]

    def align(self):
        while len(self.struct) % 4:
            self.struct += b"\0"

    def begin(self, name):
        self.struct += struct.pack(">I", FDT_BEGIN_NODE)
        self.struct += name.encode("ascii") + b"\0"
        self.align()

    def end(self):
        self.struct += struct.pack(">I", FDT_END_NODE)

    def prop(self, name, value):
        self.struct += struct.pack(">III", FDT_PROP, len(value),
                                   self.string(name))
        self.struct += value
        self.align()

    def cells(self, *values):
        return b"".join(struct.pack(">I", v) for v in values)

    def finish(self):
        self.struct += struct.pack(">I", FDT_END)
        header_size = 40
        reserve = struct.pack(">QQ", 0, 0)
        off_rsv = header_size
        off_struct = off_rsv + len(reserve)
        off_strings = off_struct + len(self.struct)
        total = off_strings + len(self.strings)
        header = struct.pack(
            ">10I", 0xD00DFEED, total, off_struct, off_strings, off_rsv,
            17, 16, 0, len(self.strings), len(self.struct))
        return header + reserve + bytes(self.struct) + bytes(self.strings)


def main():
    if len(sys.argv) != 2:
        print("usage: make_fdt_fixture.py OUTPUT", file=sys.stderr)
        return 2
    b = Builder()
    b.begin("")
    b.prop("#address-cells", b.cells(2))
    b.prop("#size-cells", b.cells(2))

    b.begin("memory@0")
    b.prop("device_type", b"memory\0")
    b.prop("reg", b.cells(0, 0, 0, 0x40000000))
    b.end()

    b.begin("soc@107c000000")
    b.prop("#address-cells", b.cells(1))
    b.prop("#size-cells", b.cells(1))
    b.prop("ranges", b.cells(0x00000000, 0x00000010, 0x00000000, 0x80000000))
    b.begin("timer@7c003000")
    b.prop("compatible", b"brcm,bcm2835-system-timer\0")
    b.prop("reg", b.cells(0x7C003000, 0x00001000))
    b.prop("clock-frequency", b.cells(1000000))
    b.end()
    b.end()

    b.begin("timer")
    b.prop("compatible", b"arm,armv8-timer\0")
    b.end()

    b.end()
    open(sys.argv[1], "wb").write(b.finish())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
