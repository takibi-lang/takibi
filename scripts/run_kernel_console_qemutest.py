#!/usr/bin/env python3
"""Read actual compiled console storage through QEMU, including refusal states.

Only this diagnostic fixture writes guest memory. It starts before guest boot,
seeds the queues with the compiler's own offsets, then uses the production
reader and collector. It proves decoding and transport, not a natural stall
or a multicore publication protocol.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from capture_kernel_console import capture, qmp


ROOT = Path(__file__).resolve().parent.parent
ELF = ROOT / "kernel/build/qemu/kernel.elf"


def sections(log):
    result = {}
    for line in log.read_text(encoding="ascii").splitlines():
        if line.startswith("console: "):
            name, payload = line[len("console: "):].split(" ", 1)
            result.setdefault(name, []).append(json.loads(payload))
    assert "console snapshot status: captured" in log.read_text(), log.read_text()
    return result


def seed(endpoint, directory, body):
    stub = str(directory / "seed-gdb")
    script = directory / "seed.gdb"
    script.write_text(
        "maintenance packet Qqemu.PhyMemMode:1\npython\n"
        "def addr(name): return int(gdb.parse_and_eval('&' + name))\n"
        "def off(record, field): return int(gdb.parse_and_eval('$takibi_' + record + '_' + field))\n"
        "def put(base, value, width=8): gdb.selected_inferior().write_memory(base, value.to_bytes(width, 'little'))\n"
        "def word(name, value): put(addr(name), value)\n"
        + body + "\nend\nmaintenance packet Qqemu.PhyMemMode:0\ndisconnect\n",
        encoding="ascii")
    result = subprocess.run([
        "gdb-multiarch", "-nx", "-q", "-batch", str(ELF),
        "-ex", f"target remote {stub}",
        "-ex", f"source {ROOT}/_build/kernel-console-layout.gdb",
        "-x", str(script)], capture_output=True, text=True, timeout=8)
    assert result.returncode == 0 and "Error" not in result.stderr, result.stdout + result.stderr


def main():
    artifacts = Path(os.environ.get("TAKIBI_LANE_ARTIFACT_ROOT", ROOT / "_build")) / "kernel-console-qemu"
    artifacts.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tk-console-test-") as temporary:
        directory = Path(temporary)
        endpoint = directory / "qmp"
        with (artifacts / "qemu.log").open("w") as output:
            guest = subprocess.Popen([
                "qemu-system-aarch64", "-machine", "virt", "-cpu", "cortex-a53",
                "-smp", "2", "-m", "1024", "-display", "none", "-monitor", "none",
                "-serial", "none", "-S", "-qmp",
                f"unix:{endpoint},server=on,wait=off", "-kernel", str(ELF)],
                stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 5
                while not endpoint.is_socket():
                    if guest.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("QEMU did not open its QMP socket")
                    time.sleep(.01)
                empty = artifacts / "empty.log"
                capture(endpoint, ELF, empty, "fixture-empty")
                state = sections(empty)
                assert state["rx"][0]["queued"] == 0
                assert not state["terminal"][0]["output_paused"]
                assert not qmp(endpoint, "query-status")["running"]
                # A collector must release its own dynamic chardev; QEMU
                # otherwise rejects a subsequent stub as a duplicate yank.
                repeated = artifacts / "repeated.log"
                capture(endpoint, ELF, repeated, "fixture-repeated")
                assert sections(repeated)["rx"][0]["queued"] == 0
                qmp(endpoint, "human-monitor-command", {
                    "command-line": f"gdbserver unix:{directory}/seed-gdb,server=on,wait=off"})
                seed(endpoint, directory, '''
core = addr('kernel_log_core_state') + off('kernellogcorestate', 'size')
put(core + off('kernellogcorestate', 'peer_length'), 4)
gdb.selected_inferior().write_memory(core + off('kernellogcorestate', 'peer_line'), b'half')
atomic_size = off('atomicword', 'size')
atomic_value = off('atomicword', 'value')
put(addr('kernel_log_peer_latest') + atomic_size + atomic_value, 10)
put(addr('kernel_log_peer_published') + 9 * atomic_size + atomic_value, 10)
put(addr('kernel_log_peer_lengths') + 9 * 8, 6)
gdb.selected_inferior().write_memory(addr('kernel_log_peer_text') + 9 * 192, b'prompt')
put(addr('terminal_output_stop_word') + atomic_value, 1)
word('terminal_echo_count', 3)
word('kernel_log_tx_count', 1)
put(0x09000038, 1 << 5, 4)
word('kernel_uart_rx_head', 2)
word('kernel_uart_rx_tail', 4094)
word('kernel_uart_rx_lines', 1)
word('kernel_uart_rx_dropped', 2)
put(addr('kernel_uart_rx_canonical'), 1, 1)
gdb.selected_inferior().write_memory(addr('kernel_uart_rx_buf') + 4094, b'a\\n')
gdb.selected_inferior().write_memory(addr('kernel_uart_rx_buf'), b'bc')
put(addr('kernel_uart_rx_marks') + 4095, 1, 1)
''')
                queued = artifacts / "queued.log"
                capture(endpoint, ELF, queued, "fixture-before-break", str(directory / "seed-gdb"))
                state = sections(queued)
                peer = state["peer"][1]
                assert peer["latest"] == 10 and peer["consumed"] == 0 and peer["overwritten"] == 2
                assert peer["partial"] == "b'half'"
                assert state["peer-record"][-1]["text"] == "b'prompt'"
                assert "publication in progress" in state["peer-record"][0]["text"]
                assert state["terminal"][0]["output_paused"]
                assert state["terminal"][0]["echo_count"] == 3
                assert state["terminal"][0]["tx_pending"]
                assert state["uart"][0]["tx_irq_enabled"]
                assert state["rx"][0]["pending"] == "b'a\\nbc'"
                assert state["rx"][0]["unfinished"] == "b'bc'"
                assert state["rx"][0]["unfinished_length"] == 2
                assert not qmp(endpoint, "query-status")["running"]
                seed(endpoint, directory, "word('kernel_uart_rx_head', 4096)\n"
                     "put(addr('kernel_log_core_state') + off('kernellogcorestate', 'size') + off('kernellogcorestate', 'peer_length'), 193)")
                damaged = artifacts / "damaged.log"
                capture(endpoint, ELF, damaged, "fixture-invalid-indices", str(directory / "seed-gdb"))
                state = sections(damaged)
                assert "invalid indices" in state["rx"][0]["status"]
                assert "invalid length" in state["peer"][1]["partial"]
                seed(endpoint, directory, "word('uart_base', 0x08000000)")
                unsafe_uart = artifacts / "unsafe-uart.log"
                capture(endpoint, ELF, unsafe_uart, "fixture-invalid-uart", str(directory / "seed-gdb"))
                try:
                    state = sections(unsafe_uart)
                except AssertionError as error:
                    raise AssertionError("unsafe UART base terminated diagnostic collection") from error
                assert "unsupported UART base" in state["uart"][0].get("status", ""), \
                    "unsafe UART base was not refused"
                assert not qmp(endpoint, "query-status")["running"]
            finally:
                guest.terminate()
                guest.wait(timeout=3)
        absent = artifacts / "unavailable.log"
        capture(directory / "absent", ELF, absent, "fixture-unavailable")
        assert "console snapshot status: unavailable:" in absent.read_text()
    print("PASS kernel/console-qemu: empty, wrapped RX/current line, peer overwrite/publication, XOFF, echo, TX IRQ, corrupt bounds/UART base, paused guest and unavailable QMP")


if __name__ == "__main__":
    main()
