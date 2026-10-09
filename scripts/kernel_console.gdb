# Read-only console snapshot. Load compiler debug metadata and the generated
# kernel-console-layout.gdb first, then run takibi-console on a stopped QEMU.
# Physical reads avoid depending on the selected process's page tables.
python
import gdb
import json


class TakibiConsole(gdb.Command):
    def __init__(self):
        super().__init__("takibi-console", gdb.COMMAND_DATA)

    def invoke(self, argument, from_tty):
        if argument.strip():
            raise gdb.GdbError("usage: takibi-console")
        metadata = globals().get("_takibi_debug_metadata")
        if metadata is None:
            raise gdb.GdbError("load takibi-debug-metadata first")
        threads = gdb.selected_inferior().threads()
        if not threads or any(not thread.is_stopped() for thread in threads):
            raise gdb.GdbError("console snapshot requires every CPU stopped")
        constants = {item["name"]: item["value"] for item in metadata["constants"]}

        def capacity(name, maximum):
            value = constants[name]
            if not 0 < value <= maximum:
                raise gdb.GdbError("unsupported console capacity: " + name)
            return value

        def layout(struct, field):
            value = gdb.parse_and_eval("$takibi_" + struct.lower() + "_" + field)
            if value.type.code == gdb.TYPE_CODE_VOID:
                raise gdb.GdbError("load kernel-console-layout.gdb first")
            return int(value)

        def address(name):
            return int(gdb.parse_and_eval("&" + name))

        def memory(base, length):
            if length == 0:
                return b""
            # gdb-memory-read: all CPUs stopped; QEMU physical mode, bounded globals or PL011 IMSC.
            return bytes(gdb.selected_inferior().read_memory(base, length))

        def integer(base, width=8):
            return int.from_bytes(memory(base, width), "little")

        def word(name):
            return integer(address(name))

        def atomic(name, index=0):
            return integer(address(name) + index * layout("AtomicWord", "size")
                           + layout("AtomicWord", "value"))

        def emit(section, **fields):
            gdb.write("console: " + section + " " + json.dumps(fields, sort_keys=True) + "\n")

        answer = gdb.execute("maintenance packet Qqemu.PhyMemMode:1", to_string=True)
        if 'received: "OK"' not in answer:
            raise gdb.GdbError("console snapshot requires QEMU physical-memory mode")
        try:
            cores = capacity("KERNEL_MAX_CORES", 64)
            records = capacity("KERNEL_LOG_PEER_RECORDS", 256)
            line_bytes = capacity("KERNEL_LOG_PEER_LINE_BYTES", 4096)
            for cpu in range(cores):
                base = address("kernel_log_core_state") + cpu * layout("KernelLogCoreState", "size")
                def field(name, width=8):
                    return integer(base + layout("KernelLogCoreState", name), width)
                latest = atomic("kernel_log_peer_latest", cpu)
                consumed = integer(address("kernel_log_peer_consumed") + cpu * 8)
                length = field("peer_length")
                emit("peer", cpu=cpu, latest=latest, consumed=consumed,
                     sequence=field("peer_sequence"), suppressed=bool(field("suppressed", 1)),
                     emergency=bool(field("emergency", 1)), partial_length=length,
                     partial=(repr(memory(base + layout("KernelLogCoreState", "peer_line"), length))
                              if length <= line_bytes else "unavailable: invalid length"),
                     truncated=bool(field("peer_truncated", 1)),
                     overwritten=max(0, latest - consumed - records))
                if consumed > latest:
                    emit("peer-invalid", cpu=cpu, reason="consumed exceeds latest")
                    continue
                for sequence in range(max(consumed + 1, latest - records + 1), latest + 1):
                    slot = cpu * records + (sequence - 1) % records
                    published = atomic("kernel_log_peer_published", slot)
                    if published != sequence:
                        emit("peer-record", cpu=cpu, sequence=sequence, published=published,
                             text="unavailable: overwritten or publication in progress")
                        continue
                    length = integer(address("kernel_log_peer_lengths") + slot * 8)
                    emit("peer-record", cpu=cpu, sequence=sequence, length=length,
                         truncated=bool(integer(address("kernel_log_peer_truncated") + slot, 1)),
                         text=(repr(memory(address("kernel_log_peer_text") + slot * line_bytes, length))
                               if length <= line_bytes else "unavailable: invalid length"))
            emit("terminal", output_paused=atomic("terminal_output_stop_word") != 0,
                 echo_count=word("terminal_echo_count"), echo_head=word("terminal_echo_head"),
                 echo_tail=word("terminal_echo_tail"), echo_dropped=word("terminal_echo_dropped"),
                 tx_count=word("kernel_log_tx_count"), tx_head=word("kernel_log_tx_head"),
                 tx_tail=word("kernel_log_tx_tail"), tx_live=bool(integer(address("kernel_log_tx_live"), 1)),
                 tx_pending=word("kernel_log_tx_count") != 0)
            uart = word("uart_base")
            # Only this QEMU virt PL011 window is safe to inspect. A damaged
            # base must not turn a diagnostic into an arbitrary MMIO read;
            # GIC reads have previously terminated QEMU during debugging.
            if uart == 0x09000000:
                imsc = integer(uart + 0x38, 4)
                emit("uart", base=hex(uart), imsc=hex(imsc), tx_irq_enabled=bool(imsc & (1 << 5)))
            else:
                emit("uart", base=hex(uart), status="unavailable: unsupported UART base")
            size = capacity("KERNEL_UART_RX_CAPACITY", 65536)
            head, tail = word("kernel_uart_rx_head"), word("kernel_uart_rx_tail")
            if head >= size or tail >= size:
                emit("rx", head=head, tail=tail, status="unavailable: invalid indices")
            else:
                queued = (head - tail) % size
                raw = memory(address("kernel_uart_rx_buf"), size)
                marks = memory(address("kernel_uart_rx_marks"), size)
                indices = [(tail + offset) % size for offset in range(queued)]
                unfinished = 0
                for index in reversed(indices):
                    if marks[index]:
                        break
                    unfinished += 1
                emit("rx", head=head, tail=tail, queued=queued,
                     dropped=word("kernel_uart_rx_dropped"), lines=word("kernel_uart_rx_lines"),
                     canonical=bool(integer(address("kernel_uart_rx_canonical"), 1)),
                     pending=repr(bytes(raw[index] for index in indices)),
                     marks=bytes(marks[index] for index in indices).hex(),
                     unfinished_length=unfinished,
                     unfinished=repr(bytes(raw[index] for index in indices[queued - unfinished:])))
        finally:
            gdb.execute("maintenance packet Qqemu.PhyMemMode:0", to_string=True)
        gdb.write("console snapshot complete\n")


TakibiConsole()
end
