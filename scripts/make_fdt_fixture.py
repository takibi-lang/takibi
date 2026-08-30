#!/usr/bin/env python3
"""Build the device-tree blob linux_user/fdt tests kernel/boot/fdt.tkb against.

GitHub issue #472.

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
    /axi/pcie@1000120000/rp1/serial@30000
                             compatible = "arm,pl011-axi"
                             reg = <0xc0 0x40030000 0 0x100>

The memory here is deliberately NOT the board's single region. It is two
nodes, and the first of them carries two `reg` tuples, because those are two
different ways a device tree says "more than one extent" and the reader
enumerates tuples across nodes rather than nodes. A fixture with one region
would pass whether or not that enumeration worked.

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

    def finish(self, reservations):
        self.struct += struct.pack(">I", FDT_END)
        header_size = 40
        reserve = b"".join(struct.pack(">QQ", address, size)
                           for address, size in reservations)
        reserve += struct.pack(">QQ", 0, 0)
        off_rsv = header_size
        off_struct = off_rsv + len(reserve)
        off_strings = off_struct + len(self.struct)
        total = off_strings + len(self.strings)
        header = struct.pack(
            ">10I", 0xD00DFEED, total, off_struct, off_strings, off_rsv,
            17, 16, 0, len(self.strings), len(self.struct))
        return header + reserve + bytes(self.struct) + bytes(self.strings)


def main():
    valid_modes = ("--invalid-memory", "--invalid-reservation",
                   "--invalid-tree-reservation", "--invalid-device",
                   "--invalid-interrupt", "--missing-interrupt")
    valid_modes = valid_modes + ("--invalid-gic",)
    valid_modes = valid_modes + ("--invalid-pcie-ranges",
                                 "--invalid-pcie-dma-ranges")
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and
                                     sys.argv[2] not in valid_modes):
        print("usage: make_fdt_fixture.py OUTPUT "
              "[--invalid-memory|--invalid-reservation|"
              "--invalid-tree-reservation|--invalid-device|"
              "--invalid-interrupt|--missing-interrupt|--invalid-gic|"
              "--invalid-pcie-ranges|--invalid-pcie-dma-ranges]",
              file=sys.stderr)
        return 2
    mode = sys.argv[2] if len(sys.argv) == 3 else ""
    b = Builder()
    b.begin("")
    b.prop("#address-cells", b.cells(2))
    b.prop("#size-cells", b.cells(2))
    b.prop("interrupt-parent", b.cells(0x8003))

    # QEMU virt's actual console shape: a root child, a compatible list, and
    # a 64-bit root reg tuple. A disabled malformed match comes first to prove
    # completed-node status, rather than property order, controls validity.
    b.begin("pl011-disabled@8ffffff")
    b.prop("compatible", b"arm,pl011\0arm,primecell\0")
    b.prop("reg", b.cells(0, 0x08FFFFFF, 0))
    b.prop("status", b"disabled\0")
    b.end()
    if mode == "--invalid-device":
        b.begin("pl011@8ffff000")
        b.prop("compatible", b"arm,pl011\0arm,primecell\0")
        b.prop("reg", b.cells(0, 0x08FFF000, 0, 0))
        b.end()
    b.begin("pl011@9000000")
    b.prop("reg", b.cells(0, 0x09000000, 0, 0x1000))
    if mode == "--invalid-interrupt":
        b.prop("interrupts", b.cells(0, 1, 0))
    elif mode != "--missing-interrupt":
        b.prop("interrupts", b.cells(0, 1, 4))
    b.prop("compatible", b"arm,pl011\0arm,primecell\0")
    b.prop("status", b"okay\0")
    b.end()

    # QEMU virt's GICv2 interrupt parent. Keep its properties after devices
    # in the structure and in a different order from the references above;
    # phandles are links, not a declaration-before-use mechanism.
    b.begin("intc@8000000")
    b.prop("#interrupt-cells", b.cells(3))
    b.prop("interrupt-controller", b"")
    b.prop("phandle", b.cells(0x8003))
    b.prop("compatible", b"arm,cortex-a15-gic\0")
    if mode == "--invalid-gic":
        b.prop("reg", b.cells(0, 0x08000000, 0, 0x10000))
    else:
        b.prop("reg", b.cells(0, 0x08000000, 0, 0x10000,
                              0, 0x08010000, 0, 0x10000))
    b.begin("v2m@8020000")
    b.prop("compatible", b"arm,gic-v2m-frame\0")
    b.prop("reg", b.cells(0, 0x08020000, 0, 0x1000))
    b.end()
    b.end()

    b.begin("memory@0")
    b.prop("device_type", b"memory\0")
    b.prop("reg", b.cells(0, 0x3F000000, 0, 0x02000000,
                          0, 0, 0, 0x40000000,
                          0, 0x41000000, 0, 0x01000000,
                          0, 0x80000000, 0, 0x10000000))
    b.end()

    b.begin("memory@100000000")
    b.prop("device_type", b"memory\0")
    b.prop("reg", b.cells(1, 0, 0, 0x20000000))
    b.end()

    # Disabled memory is not RAM available to the OS. Keep status after a
    # deliberately malformed reg so property order cannot make the parser
    # reject a node it must ignore.
    b.begin("memory@200000000")
    b.prop("device_type", b"memory\0")
    b.prop("reg", b.cells(2, 0, 0))
    b.prop("status", b"disabled\0")
    b.end()

    # The inverse order is a separate regression shape: availability is a
    # property of the completed node, not parser state at the instant reg is
    # encountered.
    b.begin("memory@210000000")
    b.prop("device_type", b"memory\0")
    b.prop("status", b"disabled\0")
    b.prop("reg", b.cells(2, 0, 0))
    b.end()

    if mode == "--invalid-memory":
        b.begin("memory@ffffffffffffffff")
        b.prop("device_type", b"memory\0")
        b.prop("reg", b.cells(0xFFFFFFFF, 0xFFFFFFFF, 0, 2))
        b.end()

    b.begin("reserved-memory")
    b.prop("#address-cells", b.cells(2))
    b.prop("#size-cells", b.cells(2))
    b.prop("ranges", b"")
    b.begin("firmware@2000")
    b.prop("reg", b.cells(0, 0x2000, 0, 0x1000))
    # Deliberately after reg: property order must not affect availability.
    b.prop("status", b"okay\0")
    b.end()
    b.begin("buffer@100001000")
    b.prop("reg", b.cells(1, 0x1000, 0, 0x1000))
    b.end()
    b.begin("disabled@30000000")
    # Even a zero-sized reg is irrelevant once the node is disabled.
    b.prop("reg", b.cells(0, 0x30000000, 0, 0))
    b.prop("status", b"disabled\0")
    b.end()
    if mode == "--invalid-tree-reservation":
        b.begin("invalid@4000")
        b.prop("reg", b.cells(0, 0x4000, 0, 0))
        b.end()
    b.end()

    # Property ORDER matters and is not fixed by the spec. These are in the
    # order the real blob writes them, `ranges` BEFORE the cell counts it
    # has to be decoded with -- which is the shape that caught a reader
    # decoding `ranges` where it found it instead of when it needed it. The
    # timer's own properties are then deliberately in an awkward order for
    # the same reason.
    b.begin("soc@107c000000")
    b.prop("compatible", b"simple-bus\0")
    b.prop("ranges", b.cells(0x00000000, 0x00000010, 0x00000000, 0x80000000))
    b.prop("#address-cells", b.cells(1))
    b.prop("#size-cells", b.cells(1))
    b.begin("timer@7c003000")
    b.prop("clock-frequency", b.cells(1000000))
    b.prop("reg", b.cells(0x7C003000, 0x00001000))
    b.prop("compatible", b"brcm,bcm2835-system-timer\0")
    b.end()

    # The real firmware has this enabled on-die UART before the RP1 subtree.
    # It deliberately shares RP1 UART0's first compatible string, proving
    # the PCIe-only lookup does not accidentally select by structure order.
    b.begin("serial@7d001000")
    b.prop("compatible", b"arm,pl011-axi\0arm,pl011\0arm,primecell\0")
    b.prop("reg", b.cells(0x7D001000, 0x1000))
    b.prop("status", b"okay\0")
    b.end()
    b.begin("interrupt-controller@7fff9000")
    if mode == "--invalid-gic":
        b.prop("reg", b.cells(0x7FFF9000, 0x1000,
                              0x7FFFA000, 0x2000,
                              0x7FFFC000, 0x2000))
    else:
        b.prop("reg", b.cells(0x7FFF9000, 0x1000,
                              0x7FFFA000, 0x2000,
                              0x7FFFC000, 0x2000,
                              0x7FFFE000, 0x2000))
    b.prop("compatible", b"arm,gic-400\0")
    b.end()
    b.begin("reset-controller@119500")
    b.prop("reg", b.cells(0x00119500, 0x10))
    b.prop("compatible", b"brcm,bcm7216-pcie-sata-rescal\0")
    b.end()
    b.begin("reset-controller@1504318")
    b.prop("reg", b.cells(0x01504318, 0x30))
    b.prop("compatible", b"brcm,brcmstb-reset\0")
    b.end()
    b.end()

    b.begin("timer")
    b.prop("compatible", b"arm,armv8-timer\0")
    b.end()

    # The concrete two-hop firmware path from the PCIe-attached RP1 UART to
    # CPU physical space. As on the board, both ranges properties precede
    # their cell-count properties. The leading PCI address cell is the
    # 32-bit non-prefetchable memory-space code, not address magnitude.
    b.begin("axi")
    b.prop("ranges", b.cells(
        0, 0, 0, 0, 0x10, 0,
        0x10, 0, 0x10, 0, 1, 0,
        0x14, 0, 0x14, 0, 4, 0,
        0x18, 0, 0x18, 0, 4, 0,
        0x1C, 0, 0x1C, 0, 4, 0))
    b.prop("#address-cells", b.cells(2))
    b.prop("#size-cells", b.cells(2))
    b.begin("msi-controller@1000131000")
    b.prop("reg", b.cells(0x10, 0x00131000, 0, 0xC0,
                          0xFF, 0xFFFFE000, 0, 0x1000))
    b.prop("compatible", b"brcm,bcm2712-mip\0")
    b.end()
    b.begin("msi-controller@1000130000")
    if mode == "--invalid-device":
        b.prop("reg", b.cells(0x10, 0x00130000, 0, 0xC0))
    else:
        b.prop("reg", b.cells(0x10, 0x00130000, 0, 0xC0,
                              0xFF, 0xFFFFF000, 0, 0x1000))
    b.prop("compatible", b"brcm,bcm2712-mip\0")
    b.end()
    for address in (0x1000100000, 0x1000110000):
        b.begin(f"pcie@{address:x}")
        b.prop("compatible", b"brcm,bcm2712-pcie\0")
        b.prop("reg", b.cells(0x10, address & 0xFFFFFFFF, 0))
        b.prop("status", b"disabled\0")
        b.end()
    b.begin("pcie@1000120000")
    b.prop("reg", b.cells(0x10, 0x00120000, 0, 0x9310))
    if mode == "--invalid-pcie-ranges":
        b.prop("ranges", b.cells(0x02000000, 0, 0,
                                 0x1F, 0, 0))
    else:
        b.prop("ranges", b.cells(0x02000000, 0, 0,
                                 0x1F, 0, 0, 0xFFFFFFFC,
                                 0x43000000, 0x4, 0,
                                 0x1C, 0, 0x3, 0))
    if mode == "--invalid-pcie-dma-ranges":
        b.prop("dma-ranges", b.cells(
            0x02000000, 0, 0, 0x1F, 0, 0))
    else:
        b.prop("dma-ranges", b.cells(
            0x02000000, 0, 0, 0x1F, 0, 0, 0x00400000,
            0x43000000, 0x10, 0, 0, 0, 0x10, 0,
            0x03000000, 0xFF, 0xFFFFF000,
            0x10, 0x00130000, 0, 0x1000))
    b.prop("compatible", b"brcm,bcm2712-pcie\0")
    b.prop("#size-cells", b.cells(2))
    b.prop("#address-cells", b.cells(3))
    b.prop("status", b"okay\0")
    b.begin("rp1")
    b.prop("ranges", b.cells(0xC0, 0x40000000,
                             0x02000000, 0, 0,
                             0, 0x00410000))
    b.prop("compatible", b"simple-bus\0")
    b.prop("#size-cells", b.cells(2))
    b.prop("#address-cells", b.cells(2))
    b.begin("serial@30000")
    b.prop("reg", b.cells(0xC0, 0x40030000, 0, 0x100))
    b.prop("status", b"okay\0")
    b.prop("compatible", b"arm,pl011-axi\0")
    b.end()
    b.begin("clocks@18000")
    b.prop("reg", b.cells(0xC0, 0x40018000, 0, 0x10038))
    b.prop("compatible", b"raspberrypi,rp1-clocks\0")
    b.end()
    b.begin("gpio@d0000")
    if mode == "--invalid-device":
        b.prop("reg", b.cells(
            0xC0, 0x400D0000, 0, 0xC000,
            0xC0, 0x400E0000, 0, 0xC000))
    else:
        b.prop("reg", b.cells(
            0xC0, 0x400D0000, 0, 0xC000,
            0xC0, 0x400E0000, 0, 0xC000,
            0xC0, 0x400F0000, 0, 0xC000))
    b.prop("compatible", b"raspberrypi,rp1-gpio\0")
    b.end()
    b.begin("ethernet@100000")
    b.prop("reg", b.cells(0xC0, 0x40100000, 0, 0x4000))
    b.prop("compatible", b"raspberrypi,rp1-gem\0cdns,macb\0")
    b.end()
    # USB1 deliberately precedes USB0 although both are enabled and share
    # one compatible string. The USB0 lookup must select by its child reg.
    b.begin("usb@300000")
    b.prop("reg", b.cells(0xC0, 0x40300000, 0, 0x100000))
    b.prop("compatible", b"snps,dwc3\0")
    b.end()
    b.begin("usb@200000")
    if mode == "--invalid-device":
        b.prop("reg", b.cells(0xC0, 0x40200000, 0))
    else:
        b.prop("reg", b.cells(0xC0, 0x40200000, 0, 0x100000))
    b.prop("compatible", b"snps,dwc3\0")
    b.end()
    b.end()
    b.end()
    b.end()

    b.end()
    # Header reservation entries split the first memory tuple and trim the
    # beginning of the second one. The first two overlap, proving exclusion
    # uses their union rather than subtracting the overlap twice. The reader
    # must enumerate five normalized usable extents. The first memory node
    # is deliberately unordered and includes overlapping and adjacent tuples;
    # their union ends at 0x42000000 and must not be counted more than once.
    reservations = [
        (0x1000, 0x1000), (0x1800, 0x1000), (0x80000000, 0x2000)
    ]
    if mode == "--invalid-reservation":
        reservations.append((0xFFFFFFFFFFFFFFFF, 2))
    open(sys.argv[1], "wb").write(b.finish(reservations))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
