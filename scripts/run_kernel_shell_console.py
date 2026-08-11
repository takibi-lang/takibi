#!/usr/bin/env python3
"""Run miniterm while reporting the kernel ash readiness marker."""

import os
import sys
import time

import serial
from serial.tools import miniterm


READY_MARKER = b"interactive shell: uart blocked\n"


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
    terminal = TimingMiniterm(serial_instance, launch_ns)
    terminal.raw = True
    terminal.set_rx_encoding("UTF-8")
    terminal.set_tx_encoding("UTF-8")
    terminal.exit_character = chr(0x1D)
    terminal.start()
    try:
        terminal.join(True)
    except KeyboardInterrupt:
        pass
    terminal.join()
    terminal.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
