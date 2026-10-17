#!/usr/bin/env python3
"""Check every kernel io struct beyond xHCI against a sourced offset table.

GitHub issue #805 (after #754). check_xhci_register_offsets.py anchors the
xHCI blocks to the xHCI specification. The other register blocks were
transcribed by hand too, so the same misplaced-field defect could sit in any
of them. This check holds one table per io struct, each with the source its
offsets were taken from, in three tiers of trust:

  spec    a public specification or vendor register reference
  linux   the Raspberry Pi Linux source, the de facto specification for the
          BCM2712 blocks that have no public datasheet (facts only: offsets,
          array sizes; file and commit named in SOURCES)
  board   a value fixed by hardware evidence on the RPi5, or derived from a
          sourced neighbour by a stated stride rule; trusted, named in
          TRUSTED_BASE.md

Rules, all errors:
1. Every io struct under kernel/ has a table here (or is one of the xHCI
   blocks the xHCI check owns). A new block cannot land without one.
2. Every field of a block is in its table, at the table's offset, and an
   array field has the table's element count.
3. Every table names a struct that exists, so a renamed block does not leave
   a table checking nothing.

What it cannot see: whether a source itself is right for this silicon. The
GEM table cites two independent sources that agree (Microchip's PolarFire
SoC register header and Linux macb.h), and RPi5 TX working with a nonzero
upper address word is the board evidence for TBQPH (TRUSTED_BASE.md).

Controls: scripts/check_register_offsets_controls.py.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import per_file


ROOT = Path(__file__).resolve().parents[1]
KERNEL = ROOT / "kernel"

LINUX = "raspberrypi/linux bba53a117a4a5c29da892962332ff1605990e17a (rpi-6.6.y)"
SOURCES = {
    "gicv2": ("spec", "ARM IHI 0048B, GICv2 Architecture Specification, "
              "4.1.2 (distributor) and 4.1.3 (CPU interface) register maps"),
    "pl011": ("spec", "ARM DDI 0183, PrimeCell UART (PL011) TRM, 3.2 summary"),
    "virtio": ("spec", "Virtual I/O Device (VIRTIO) 1.x, 4.2.2 MMIO Device "
               "Register Layout"),
    "bcm2835-timer": ("spec", "BCM2835 ARM Peripherals, 12 System Timer "
                      "(CLO at +0x04); BCM2712 keeps the block"),
    "pci-type1": ("spec", "PCI Local Bus Specification 3.0, 6.1 Type 1 "
                  "configuration header (command 0x04, bus numbers 0x18, "
                  "memory base/limit 0x20)"),
    "pci-msix": ("spec", "PCI Local Bus Specification 3.0, 6.8.2 MSI-X table, "
                 "16-byte entries; RP1 implements 61 vectors (RP1 Peripherals "
                 "RP-008370-DS, 6.1)"),
    "rp1-msix-cfg": ("spec", "RP1 Peripherals RP-008370-DS, 6.1 MSIX_CFG_n; "
                     "the handle starts at MSIX_CFG_0's SET alias"),
    "gem": ("spec", "Microchip PolarFire SoC MSS GEM register header "
            "mss_ethernet_registers.h (polarfire-soc-bare-metal-library "
            "7c18b9eab4ec70e7b394253ef41dda27882a827f, MIT), agreeing with "
            "Linux drivers/net/ethernet/cadence/macb.h at " + LINUX),
    "brcmstb-pcie": ("linux", "drivers/pci/controller/pcie-brcmstb.c at "
                     + LINUX + " (pcie_offsets_bcm2712 for HARD_DEBUG)"),
    "brcmstb-pcie-stride": ("board", "UBUS_BAR2_CONFIG_REMAP_HI: Linux names "
                            "only BAR1 LO/HI (0x40ac/0x40b0) and BAR2 LO "
                            "(0x40b4); HI at LO + 4 by that stride"),
    "rescal": ("linux", "drivers/reset/reset-brcmstb-rescal.c at " + LINUX),
    "brcmstb-reset": ("linux", "drivers/reset/reset-brcmstb.c at " + LINUX
                      + " (SW_INIT_SET/CLEAR, bank size 0x18)"),
    "bcm2712-mip": ("linux", "drivers/irqchip/irq-bcm2712-mip.c at " + LINUX),
}

# struct -> {field: (offset, element count or None for a scalar, source)}
TABLES = {
    "GicV2Distributor": {
        "ctlr": (0x000, None, "gicv2"),
        "isenabler": (0x100, 32, "gicv2"),
        "icpendr": (0x280, 32, "gicv2"),
        "itargetsr": (0x800, 1024, "gicv2"),
        "icfgr": (0xC00, 64, "gicv2"),
        "sgir": (0xF00, None, "gicv2"),
    },
    "GicV2CpuInterface": {
        "ctlr": (0x00, None, "gicv2"),
        "pmr": (0x04, None, "gicv2"),
        "iar": (0x0C, None, "gicv2"),
        "eoir": (0x10, None, "gicv2"),
    },
    "Pl011Regs": {name: (offset, None, "pl011") for name, offset in {
        "dr": 0x00, "fr": 0x18, "ibrd": 0x24, "fbrd": 0x28, "lcrh": 0x2C,
        "cr": 0x30, "ifls": 0x34, "imsc": 0x38, "mis": 0x40, "icr": 0x44,
    }.items()},
    "VirtioMmioRegs": {**{name: (offset, None, "virtio") for name, offset in {
        "magic": 0x00, "version": 0x04, "device_id": 0x08,
        "device_features": 0x10, "device_features_sel": 0x14,
        "driver_features": 0x20, "driver_features_sel": 0x24,
        "queue_sel": 0x30, "queue_num_max": 0x34, "queue_num": 0x38,
        "queue_ready": 0x44, "queue_notify": 0x50, "interrupt_status": 0x60,
        "interrupt_ack": 0x64, "status": 0x70, "queue_desc_low": 0x80,
        "queue_desc_high": 0x84, "queue_driver_low": 0x90,
        "queue_driver_high": 0x94, "queue_device_low": 0xA0,
        "queue_device_high": 0xA4,
    }.items()}, "config_word": (0x100, 2, "virtio")},
    "Rpi5SystemTimerRegs": {"clo": (0x04, None, "bcm2835-timer")},
    "Rp1GemRegs": {name: (offset, None, "gem") for name, offset in {
        "ncr": 0x00, "ncfgr": 0x04, "nsr": 0x08, "ur": 0x0C, "dmacfg": 0x10,
        "tsr": 0x14, "rbqp": 0x18, "tbqp": 0x1C, "rsr": 0x20, "isr": 0x24,
        "ier": 0x28, "idr": 0x2C, "imr": 0x30, "man": 0x34,
        "rx_cutthrough": 0x44, "axi_pipe": 0x54, "sa1_bottom": 0x88,
        "sa1_top": 0x8C, "tbqph": 0x4C8, "rbqph": 0x4D4,
    }.items()},
    "Pcie2Regs": {
        "root_command_status": (0x0004, None, "pci-type1"),
        "root_bus_numbers": (0x0018, None, "pci-type1"),
        "root_memory_base_limit": (0x0020, None, "pci-type1"),
        **{name: (offset, None, "brcmstb-pcie") for name, offset in {
            "id_val3": 0x043C, "mdio_addr": 0x1100, "mdio_wr_data": 0x1104,
            "phy_ctl_15": 0x184C, "misc_ctrl": 0x4008, "win0_lo": 0x400C,
            "win0_hi": 0x4010, "rc_bar1_lo": 0x402C, "rc_bar1_hi": 0x4030,
            "rc_bar2_lo": 0x4034, "rc_bar2_hi": 0x4038, "pcie_ctrl": 0x4064,
            "pcie_status": 0x4068, "win0_base_limit": 0x4070,
            "win0_base_hi": 0x4080, "win0_limit_hi": 0x4084,
            "ubus_bar1_remap_lo": 0x40AC, "ubus_bar1_remap_hi": 0x40B0,
            "ubus_bar2_remap_lo": 0x40B4, "hard_debug": 0x4304,
            "ext_cfg_index": 0x9000,
        }.items()},
        "ubus_bar2_remap_hi": (0x40B8, None, "brcmstb-pcie-stride"),
        "ext_cfg_data": (0x8000, 1024, "brcmstb-pcie"),
    },
    "PcieRescalRegs": {
        "start": (0x00, None, "rescal"),
        "status": (0x08, None, "rescal"),
    },
    "BcmResetRegs": {
        "bank1_set": (0x18, None, "brcmstb-reset"),
        "bank1_clear": (0x1C, None, "brcmstb-reset"),
    },
    "Rp1Mip": {
        "cfg_low_host": (0x20, None, "bcm2712-mip"),
        "mask_low_host": (0x40, None, "bcm2712-mip"),
        "mask_low_vpu": (0x60, None, "bcm2712-mip"),
    },
    "Rp1MsixTable": {"words": (0x0, 61 * 4, "pci-msix")},
    "Rp1MsixCfgSet": {"cfg": (0x0, 64, "rp1-msix-cfg")},
}

# Checked against the xHCI specification by check_xhci_register_offsets.py.
XHCI_OWNED = {"XhciCapabilityRegs", "XhciOperationalRegs", "XhciRuntimeRegs",
              "XhciDoorbellRegs"}

STRUCT = re.compile(r"^io\s+struct\s+(\w+)\s*\{(.*?)\n\}", re.S | re.M)
FIELD = re.compile(r"^\s*(\w+)\s*:\s*(\[[^\]]*\]|[^;\[]*?)\s+at\s+"
                   r"(0x[0-9A-Fa-f]+|\d+)\s*;", re.M)
ARRAY = re.compile(r"\[\s*\w+\s*;\s*(0x[0-9A-Fa-f]+|\d+)\s*\]")


@per_file
def io_structs(text: str) -> tuple:
    """(struct, ((field, offset, count or None), ...)) for each io struct."""
    found = []
    for name, body in STRUCT.findall(text):
        fields = []
        for line in body.splitlines():
            line = line.split("//")[0].strip()
            if line and not FIELD.match(line):
                fields.append((line, -1, None))
        for field, ty, offset in FIELD.findall(body):
            array = ARRAY.fullmatch(ty.strip())
            fields.append((field, int(offset, 0),
                           int(array.group(1), 0) if array else None))
        found.append((name, tuple(fields)))
    return tuple(found)


def problems(sources: dict[str, str], tables: dict = TABLES) -> tuple[list[str], int]:
    """`sources` maps a path to its text. Returns (failures, fields checked)."""
    failures: list[str] = []
    seen: set[str] = set()
    count = 0
    for path in sorted(sources):
        for struct, fields in io_structs(sources[path]):
            seen.add(struct)
            if struct in XHCI_OWNED:
                continue
            table = tables.get(struct)
            if table is None:
                failures.append(f"{path}: io struct {struct} has no sourced "
                                "offset table; add one to TABLES with its "
                                "SOURCES entry")
                continue
            for field, offset, elements in fields:
                count += 1
                if offset < 0:
                    failures.append(f"{path}: {struct}: cannot read the field "
                                    f"line {field!r}")
                    continue
                expected = table.get(field)
                if expected is None:
                    failures.append(f"{path}: {struct}.{field} is not in its "
                                    "offset table; add it from the source")
                    continue
                want, want_elements, source = expected
                cite = SOURCES[source][1]
                if offset != want:
                    failures.append(f"{path}: {struct}.{field} at {offset:#x}, "
                                    f"{cite} puts it at {want:#x}")
                if elements != want_elements:
                    failures.append(f"{path}: {struct}.{field} has "
                                    f"{elements or 'no'} elements, the table "
                                    f"has {want_elements or 'none'} ({cite})")
    for struct in sorted(set(tables) - seen):
        failures.append(f"offset table {struct} names no io struct under kernel/")
    return failures, count


def kernel_sources() -> dict[str, str]:
    return {str(path.relative_to(ROOT)): path.read_text()
            for path in sorted(KERNEL.rglob("*.tkb"))}


def main() -> int:
    for table in TABLES.values():
        for _, _, source in table.values():
            if source not in SOURCES:
                print(f"FAIL register-offsets: unknown source {source!r}")
                return 1
    failures, count = problems(kernel_sources())
    if failures:
        print("FAIL register-offsets:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    report_pass("register-offsets",
                f"{count} fields of {len(TABLES)} io structs beyond xHCI match "
                "their sourced offset tables", fields=count, structs=len(TABLES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
