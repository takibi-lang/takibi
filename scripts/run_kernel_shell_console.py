#!/usr/bin/env python3
"""Run miniterm while reporting the kernel ash readiness marker."""

import os
import signal
import sys
import time

import serial
from serial.tools import miniterm


READY_MARKER = b"interactive shell: uart blocked\n"
BOOT_PHASE_MARKERS = (
    (b"takibi kernel:", "kernel entry"),
    (b"memory:", "memory detection"),
    (b"smp bringup:", "SMP bringup"),
    (b"virtio net: link", "virtio-net init"),
    (b"virtio net: arp reply", "ARP fixture"),
    (b"virtio net: icmp echo", "ICMP fixture"),
    (b"virtio net: tcp handshake", "TCP fixture"),
    (b"virtio net: rx capability", "network capability"),
    (b"virtio blk: ext2 backend", "virtio-blk/ext2 init"),
    (b"ext2 mount:", "ext2 mount"),
    (b"rootfs image:", "rootfs image resolve"),
    (b"interactive shell: uart blocked", "ash readiness"),
)


class TimingMiniterm(miniterm.Miniterm):
    def __init__(self, serial_instance, launch_ns):
        super().__init__(serial_instance, echo=True, eol="lf")
        self.launch_ns = launch_ns
        self.pending = b""
        self.reported = False

    def reader(self):
        try:
            while self.alive and self._reader_alive:
                data = self.serial.read(self.serial.in_waiting or 1)
                if not data:
                    continue
                if not self.reported:
                    self.pending = (self.pending + data)[-len(READY_MARKER):]
                    if READY_MARKER in self.pending:
                        elapsed_ms = (time.time_ns() - self.launch_ns) / 1_000_000
                        print(
                            f"[kernel/qemu] ash readiness: {elapsed_ms:.1f} ms "
                            "(interactive shell UART blocked)",
                            file=sys.stderr,
                            flush=True,
                        )
                        self.reported = True
                if self.raw:
                    self.console.write_bytes(data)
                else:
                    text = self.rx_decoder.decode(data)
                    for transformation in self.rx_transformations:
                        text = transformation.rx(text)
                    self.console.write(text)
        except serial.SerialException:
            self.alive = False
            self.console.cancel()
            raise


def main() -> int:
    port = sys.argv[1]
    baudrate = int(sys.argv[2])
    launch_ns = int(os.environ["KERNEL_QEMU_SHELL_LAUNCH_NS"])
    serial_instance = serial.serial_for_url(port, baudrate, do_not_open=True)
    serial_instance.open()
    connected_ms = (time.time_ns() - launch_ns) / 1_000_000
    print(
        f"[kernel/qemu] UART connected: {connected_ms:.1f} ms after QEMU launch",
        file=sys.stderr,
        flush=True,
    )
    if os.environ.get("KERNEL_QEMU_SHELL_MEASURE_ONLY") == "1":
        pending = b""
        line_buffer = b""
        reported_phases = set()
        while True:
            data = serial_instance.read(serial_instance.in_waiting or 1)
            if not data:
                continue
            line_buffer += data
            while b"\n" in line_buffer:
                line, line_buffer = line_buffer.split(b"\n", 1)
                for marker, phase in BOOT_PHASE_MARKERS:
                    if phase not in reported_phases and marker in line:
                        elapsed_ms = (time.time_ns() - launch_ns) / 1_000_000
                        print(
                            f"[kernel/qemu] {phase}: {elapsed_ms:.1f} ms",
                            file=sys.stderr,
                            flush=True,
                        )
                        reported_phases.add(phase)
            pending = (pending + data)[-len(READY_MARKER):]
            if READY_MARKER in pending:
                elapsed_ms = (time.time_ns() - launch_ns) / 1_000_000
                if "ash readiness" not in reported_phases:
                    print(
                        f"[kernel/qemu] ash readiness: {elapsed_ms:.1f} ms "
                        "(interactive shell UART blocked)",
                        file=sys.stderr,
                        flush=True,
                    )
                return 0
    terminal = TimingMiniterm(serial_instance, launch_ns)
    terminal.raw = True
    terminal.set_rx_encoding("UTF-8")
    terminal.set_tx_encoding("UTF-8")
    terminal.exit_character = chr(0x1D)

    def stop_terminal(_signum, _frame):
        terminal.stop()
        if hasattr(terminal.serial, "cancel_read"):
            terminal.serial.cancel_read()

    signal.signal(signal.SIGINT, stop_terminal)
    signal.signal(signal.SIGTERM, stop_terminal)
    terminal.start()
    try:
        terminal.join(True)
    except KeyboardInterrupt:
        terminal.stop()
    finally:
        terminal.stop()
        terminal.join()
        terminal.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
