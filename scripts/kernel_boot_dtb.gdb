# Source after loading a maintained kernel ELF and stopping after _start has
# saved x0. takibi-dtb is read-only: it validates the FDT magic and prints the
# bounded header fields needed to distinguish a bad handoff from a bad parser.

python
import gdb
import struct


class TakibiDtb(gdb.Command):
    """Validate and summarize the boot DTB header saved by arm64 entry."""

    def __init__(self):
        super().__init__("takibi-dtb", gdb.COMMAND_DATA)

    def invoke(self, argument, from_tty):
        if argument.strip():
            raise gdb.GdbError("usage: takibi-dtb")
        inferior = gdb.selected_inferior()
        slot = int(gdb.parse_and_eval("&boot_dtb_address"))
        pointer = bytes(inferior.read_memory(slot, 8))
        dtb = int.from_bytes(pointer, byteorder="little")
        header = bytes(inferior.read_memory(dtb, 40))
        if header[:4] != bytes.fromhex("d00dfeed"):
            gdb.write(
                f"dtb: address=0x{dtb:x} invalid magic={header[:4].hex()}\n")
            return
        fields = struct.unpack(">10I", header)
        total, structure, strings = fields[1], fields[2], fields[3]
        version = fields[5]
        gdb.write(
            f"dtb: address=0x{dtb:x} magic=ok total={total} "
            f"struct_offset={structure} strings_offset={strings} "
            f"version={version}\n")


TakibiDtb()
end
