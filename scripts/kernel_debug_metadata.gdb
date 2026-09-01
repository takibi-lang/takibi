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
        if metadata.get("format") != 1:
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


TakibiDebugMetadata()
TakibiEnum()
TakibiConstant()
TakibiVariantLayout()
end
