# Churn diagnostics and forward-only ASID injection on a stopped QEMU.
# Layouts are compiler-generated; never read interrupt-controller MMIO.
python
import gdb
import json
import re


class TakibiChurn(gdb.Command):
    def __init__(self):
        super().__init__("takibi-churn", gdb.COMMAND_DATA)

    def invoke(self, argument, from_tty):
        args = gdb.string_to_argv(argument)
        if len(args) not in (1, 2):
            raise gdb.GdbError("usage: takibi-churn LAYOUT [ASID_NEXT]")
        with open(args[0], encoding="ascii") as stream:
            layout = dict((key, int(value)) for key, value in re.findall(
                r"^set \$takibi_(\S+) = ([0-9]+)$", stream.read(), re.M))
        threads = gdb.selected_inferior().threads()
        if not threads or any(not thread.is_stopped() for thread in threads):
            raise gdb.GdbError("churn inspection requires every CPU stopped")

        def offset(struct, field):
            return layout[struct.lower() + "_" + field]

        def address(name):
            return int(gdb.parse_and_eval("&" + name))

        def word(base):
            # gdb-memory-read: stopped CPUs, physical mode, bounded ASID/world-stop globals.
            return int.from_bytes(bytes(gdb.selected_inferior().read_memory(base, 8)), "little")

        reply = gdb.execute("maintenance packet Qqemu.PhyMemMode:1", to_string=True)
        if 'received: "OK"' not in reply:
            raise gdb.GdbError("churn inspection requires QEMU physical-memory mode")
        try:
            cell = address("asid_cell")
            state = cell + offset("LockedCell$AsidState", "value")
            lock = cell + offset("LockedCell$AsidState", "lock") + offset("Mutex", "word")
            next_address = state + offset("AsidState", "next")
            current = word(next_address)
            last = word(address("asid_last"))
            if len(args) == 2:
                requested = int(args[1])
                if word(lock):
                    gdb.write("churn ASID jump deferred: lock held\n")
                    return
                if not current < requested <= last:
                    raise gdb.GdbError("ASID jump must advance the current counter within its width")
                # gdb-memory-write: explicit test injection, stopped CPUs and an unheld cell lock.
                gdb.selected_inferior().write_memory(next_address, requested.to_bytes(8, "little"))
                if word(next_address) != requested:
                    raise gdb.GdbError("ASID jump readback failed")
                gdb.write("churn ASID jump complete: %d -> %d\n" % (current, requested))
            else:
                gdb.execute("info threads")
                gdb.execute("thread apply all bt 12")
                gdb.execute("thread apply all info registers pc sp cpsr")
                stop = address("kernel_world_stop")
                atomic = offset("AtomicWord", "value")
                fields = {name: word(stop + offset("WorldStop", name) + atomic)
                          for name in ("claimed", "owner", "requested", "participants")}
                fields["generation"] = word(stop + offset("WorldStop", "generation"))
                # Capacity comes from compiler metadata; do not count padding
                # before the next field as another acknowledgement.
                from pathlib import Path
                with open(Path(args[0]).parent / "kernel-debug-metadata.json", encoding="ascii") as stream:
                    constants = {item["name"]: item["value"] for item in json.load(stream)["constants"]}
                cores = constants["KERNEL_MAX_CORES"]
                start = offset("WorldStop", "ack")
                end = offset("WorldStop", "participants")
                stride = offset("AtomicWord", "size")
                if not stride or not 0 < cores <= 64 or start + cores * stride > end:
                    raise gdb.GdbError("unsupported world-stop acknowledgement layout")
                fields["acks"] = [word(stop + start + cpu * stride + atomic) for cpu in range(cores)]
                fields["owner_cpu"] = fields["owner"] - 1 if fields["owner"] else None
                fields["asid_next"] = current
                fields["asid_generation"] = word(state + offset("AsidState", "generation"))
                gdb.write("churn world stop: " + json.dumps(fields, sort_keys=True) + "\n")
                gdb.write("churn stall dump complete\n")
        finally:
            gdb.execute("maintenance packet Qqemu.PhyMemMode:0", to_string=True)


TakibiChurn()
end
