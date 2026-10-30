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
            line_bytes = capacity("KERNEL_LOG_LINE_BYTES", 4096)
            # Each CPU's staged kernel line (#613 slice 5): what it has
            # written of a line that has not reached its newline, so neither
            # the ring nor the UART has it yet.
            for cpu in range(cores):
                base = address("kernel_log_core_state") + cpu * layout("KernelLogCoreState", "size")
                def field(name, width=8):
                    return integer(base + layout("KernelLogCoreState", name), width)
                length = field("length")
                active = bool(field("active", 1))
                emit("peer", cpu=cpu, capturing=bool(field("capturing", 1)),
                     emergency=bool(field("emergency", 1)), active=active,
                     continued=bool(field("continued", 1)), partial_length=length,
                     partial=((repr(memory(base + layout("KernelLogCoreState", "line"), length))
                               if active else "b''")
                              if length <= line_bytes else "unavailable: invalid length"))
            emit("terminal", output_paused=atomic("terminal_output_stop_word") != 0,
                 echo_count=atomic("terminal_echo_count"),
                 echo_head=integer(address("terminal_echo_state") + layout("TerminalEchoState", "head")),
                 echo_tail=integer(address("terminal_echo_state") + layout("TerminalEchoState", "tail")),
                 echo_dropped=atomic("terminal_echo_dropped"),
                 tx_count=atomic("kernel_log_tx_count"),
                 tx_head=integer(address("kernel_log_tx_state") + layout("KernelLogTxState", "head")),
                 tx_tail=integer(address("kernel_log_tx_state") + layout("KernelLogTxState", "tail")),
                 tx_live=atomic("kernel_log_tx_armed") != 0 and atomic("kernel_console_owner") == 0,
                 console_owner=hex(atomic("kernel_console_owner")),
                 tx_pending=atomic("kernel_log_tx_count") != 0)
            uart = word("uart_base")
            # Only this QEMU virt PL011 window is safe to inspect. A damaged
            # base must not turn a diagnostic into an arbitrary MMIO read;
            # GIC reads have previously terminated QEMU during debugging.
            # Zero is an unwritten BootOnce cell (#1013): before the boot attach
            # no window is known, which is a state and not a damaged base.
            if uart == 0:
                emit("uart", base=hex(uart), status="unavailable: UART base not yet written")
            elif uart == 0x09000000:
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
            ticks = [atomic("secondary_tick_count", cpu) for cpu in range(cores)]
        finally:
            gdb.execute("maintenance packet Qqemu.PhyMemMode:0", to_string=True)
        # GitHub issue #854: a boot probe that stalls names no core in the
        # UART log, and the serial BREAK cannot reach DDB while core 0 spins
        # with IRQs masked. Every vCPU's PC, its symbol, whether IRQs are
        # masked, and its tick count say which core waits on which.
        # QEMU numbers its GDB threads 1.. in CPU index order.
        selected = gdb.selected_thread()
        try:
            for thread in sorted(threads, key=lambda item: item.num):
                try:
                    thread.switch()
                    frame = gdb.newest_frame()
                    pc = int(frame.read_register("pc")) & 0xFFFFFFFFFFFFFFFF
                    sp = int(frame.read_register("sp")) & 0xFFFFFFFFFFFFFFFF
                    pstate = int(frame.read_register("cpsr")) & 0xFFFFFFFF
                    symbol = gdb.execute(f"info symbol {pc:#x}", to_string=True).strip()
                    cpu = thread.num - 1
                    emit("cpu", cpu=cpu, pc=hex(pc), sp=hex(sp), symbol=symbol,
                         irq_masked=bool(pstate & (1 << 7)), el=(pstate >> 2) & 3,
                         ticks=ticks[cpu] if 0 <= cpu < len(ticks) else None)
                except Exception as error:  # one unreadable vCPU must not hide the rest
                    emit("cpu", thread=thread.num, status="unavailable: " + str(error))
        finally:
            if selected is not None:
                selected.switch()
        gdb.write("console snapshot complete\n")


TakibiConsole()
end
