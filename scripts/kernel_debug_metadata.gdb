# Load and query compiler-emitted Takibi debug metadata from GDB.
python
import json
import gdb


_takibi_debug_metadata = None


def _takibi_named(items, name, kind):
    for item in items:
        if item["name"] == name:
            return item
    raise gdb.GdbError(f"unknown Takibi {kind} '{name}'")


def _takibi_value(expression):
    try:
        return int(gdb.parse_and_eval(expression))
    except gdb.error as error:
        raise gdb.GdbError(f"cannot evaluate '{expression}': {error}")


class TakibiDebugMetadata(gdb.Command):
    """Load a JSON sidecar emitted by --emit-debug-metadata."""

    def __init__(self):
        super().__init__("takibi-debug-metadata", gdb.COMMAND_DATA)

    def invoke(self, argument, from_tty):
        global _takibi_debug_metadata
        args = gdb.string_to_argv(argument)
        if len(args) != 1:
            raise gdb.GdbError("usage: takibi-debug-metadata PATH")
        with open(args[0], "r", encoding="ascii") as stream:
            metadata = json.load(stream)
        if metadata.get("format") not in (1, 2):
            raise gdb.GdbError("unsupported Takibi debug metadata format")
        _takibi_debug_metadata = metadata
        gdb.write(
            "takibi-debug-metadata: "
            f"enums={len(metadata['enums'])} "
            f"variants={len(metadata['variants'])} "
            f"constants={len(metadata['constants'])}\n")


class TakibiEnum(gdb.Command):
    """Render an integer expression through a named Takibi enum."""

    def __init__(self):
        super().__init__("takibi-enum", gdb.COMMAND_DATA)

    def invoke(self, argument, from_tty):
        if _takibi_debug_metadata is None:
            raise gdb.GdbError("load metadata with takibi-debug-metadata first")
        type_name, separator, expression = argument.strip().partition(" ")
        if not separator or not expression.strip():
            raise gdb.GdbError("usage: takibi-enum TYPE EXPRESSION")
        enum = _takibi_named(
            _takibi_debug_metadata["enums"], type_name, "enum")
        value = _takibi_value(expression)
        matches = [case["name"] for case in enum["cases"]
                   if case["value"] == value]
        if matches:
            gdb.write(f"{type_name}::{matches[0]} ({value})\n")
        else:
            gdb.write(f"{type_name}::<unknown> ({value})\n")


class TakibiConstant(gdb.Command):
    """Render an integer expression through constants sharing a name prefix."""

    def __init__(self):
        super().__init__("takibi-constant", gdb.COMMAND_DATA)

    def invoke(self, argument, from_tty):
        if _takibi_debug_metadata is None:
            raise gdb.GdbError("load metadata with takibi-debug-metadata first")
        prefix, separator, expression = argument.strip().partition(" ")
        if not separator or not expression.strip():
            raise gdb.GdbError("usage: takibi-constant PREFIX EXPRESSION")
        value = _takibi_value(expression)
        matches = [item["name"] for item in _takibi_debug_metadata["constants"]
                   if item["name"].startswith(prefix) and
                   item["value"] == value]
        if len(matches) == 1:
            gdb.write(f"{matches[0]} ({value})\n")
        elif not matches:
            gdb.write(f"{prefix}<unknown> ({value})\n")
        else:
            raise gdb.GdbError(
                f"ambiguous Takibi constant prefix '{prefix}' for {value}: " +
                ", ".join(matches))


class TakibiVariantLayout(gdb.Command):
    """Print compiler-owned tag and payload layout for a closed variant."""

    def __init__(self):
        super().__init__("takibi-variant-layout", gdb.COMMAND_DATA)

    def invoke(self, argument, from_tty):
        if _takibi_debug_metadata is None:
            raise gdb.GdbError("load metadata with takibi-debug-metadata first")
        args = gdb.string_to_argv(argument)
        if len(args) != 1:
            raise gdb.GdbError("usage: takibi-variant-layout TYPE")
        variant = _takibi_named(
            _takibi_debug_metadata["variants"], args[0], "variant")
        gdb.write(
            f"{variant['name']}: size={variant['size']} "
            f"tag_offset={variant['tag_offset']} "
            f"tag_size={variant['tag_size']}\n")
        for case in variant["cases"]:
            payload = case["payload"]
            if payload is None:
                detail = "payload=none"
            else:
                detail = (f"payload_type={payload['type']} "
                          f"payload_offset={payload['offset']} "
                          f"payload_size={payload['size']}")
            gdb.write(
                f"{variant['name']}::{case['name']} "
                f"tag={case['tag']} {detail}\n")


class TakibiForceVariantReturn(gdb.Command):
    """Return immediately from the current function with a payload-free variant case."""

    def __init__(self):
        super().__init__("takibi-force-variant-return", gdb.COMMAND_RUNNING)

    def invoke(self, argument, from_tty):
        if _takibi_debug_metadata is None:
            raise gdb.GdbError("load metadata with takibi-debug-metadata first")
        args = gdb.string_to_argv(argument)
        if len(args) != 2:
            raise gdb.GdbError(
                "usage: takibi-force-variant-return TYPE CASE")
        variant = _takibi_named(
            _takibi_debug_metadata["variants"], args[0], "variant")
        case = _takibi_named(variant["cases"], args[1], "variant case")
        if case["payload"] is not None:
            raise gdb.GdbError(
                "takibi-force-variant-return only supports payload-free cases")
        abi = variant.get("return_abi")
        if abi is None:
            raise gdb.GdbError(
                "metadata has no supported return ABI for this target")

        tag_bytes = int(case["tag"]).to_bytes(
            variant["tag_size"], byteorder="little", signed=False)
        value_bytes = bytearray(variant["size"])
        tag_offset = variant["tag_offset"]
        value_bytes[tag_offset:tag_offset + len(tag_bytes)] = tag_bytes

        register_values = []
        if abi["kind"] == "registers":
            for part in abi["parts"]:
                start = part["offset"]
                end = start + part["size"]
                register_values.append((
                    part["register"],
                    int.from_bytes(value_bytes[start:end], "little")))
        elif abi["kind"] == "indirect":
            address = int(gdb.parse_and_eval(f"${abi['pointer_register']}"))
            gdb.selected_inferior().write_memory(address, value_bytes)
        else:
            raise gdb.GdbError(
                f"unsupported Takibi return ABI kind '{abi['kind']}'")

        # A source-line breakpoint normally lands after the machine prologue,
        # so changing PC to x30 would leave SP and callee-saved registers in
        # the callee's frame. Let GDB unwind the selected frame, then install
        # direct-result registers in the restored caller context.
        gdb.execute("return")
        for register, value in register_values:
            gdb.execute(f"set ${register} = {value}")
        gdb.write(
            "takibi-force-variant-return: "
            f"{variant['name']}::{case['name']} via {abi['kind']}\n")


TakibiDebugMetadata()
TakibiEnum()
TakibiConstant()
TakibiVariantLayout()
TakibiForceVariantReturn()
end
