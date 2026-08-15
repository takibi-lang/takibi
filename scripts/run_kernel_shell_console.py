#!/usr/bin/env python3
"""Run miniterm while reporting the kernel ash readiness marker."""

import os
import signal
import sys
import time

import serial
from serial.tools import miniterm


# The bounded init.sh fixture emits the first marker while it exercises ash.
# The shell exposed by kernelsh-* is its persistent self-replacement and emits
# the second one. Accept both so this console remains usable while booting an
# older image, but report the persistent shell as ready for current images.
READY_MARKERS = (
    b"persistent shell: uart blocked\n",
    b"interactive shell: uart blocked\n",
)
READY_MARKER_WINDOW = max(len(marker) for marker in READY_MARKERS)
PLATFORM = os.environ.get("KERNEL_SHELL_PLATFORM", "qemu")
LABEL = f"[kernel/{PLATFORM}]"

# kernelsh-qemu backgrounds `qemu-system-aarch64` (server=on,wait=off) and
# connects to its TCP UART socket with no synchronization between the two --
# there is no signal for "the listen socket is bound yet". Under light load
# QEMU binds it well before this script even finishes importing pyserial, so
# the race is invisible; under heavy concurrent load (this project's own
# `make allcheck` runs the QEMU and RPi5 lanes in parallel, and RPi5's SWD
# flash step is CPU-heavy) QEMU's own process start can lose the race,
# producing an immediate ECONNREFUSED (Linux refuses a connect() to a port
# with nothing listening yet rather than queuing it) that looked, before this
# retry loop existed, like a hard failure with no way to tell "QEMU was just
# slow to bind" apart from "QEMU crashed on startup" from the log alone.
OPEN_RETRY_TIMEOUT_SECONDS = 10
OPEN_RETRY_INTERVAL_SECONDS = 0.2


def backend_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def open_with_retry(serial_instance) -> None:
    """Open serial_instance, retrying past a transient connection-refused
    race with the backend process (QEMU's own socket bind, or -- for
    RPi5 -- a USB serial device that has not finished enumerating yet).
    Every retry is logged so a recurrence leaves a timeline in the log
    instead of a single opaque traceback: how many attempts it took (or
    that every attempt failed), and whether the backend process was
    still alive at the point this gave up -- alive means "still just
    slow, raise the timeout"; dead means "it exited/crashed, look at
    why" rather than assuming the two are the same failure."""
    backend_pid_env = os.environ.get("KERNEL_SHELL_BACKEND_PID")
    backend_pid = int(backend_pid_env) if backend_pid_env else None
    deadline = time.monotonic() + OPEN_RETRY_TIMEOUT_SECONDS
    attempt = 0
    last_error: Exception | None = None
    while True:
        attempt += 1
        try:
            serial_instance.open()
            if attempt > 1:
                print(
                    f"{LABEL} UART open succeeded on attempt {attempt} "
                    f"(after {OPEN_RETRY_INTERVAL_SECONDS * (attempt - 1):.1f}s "
                    "of connection-refused retries -- the backend process was "
                    "just slow to bind, not crashed)",
                    file=sys.stderr,
                    flush=True,
                )
            return
        except serial.SerialException as exc:
            last_error = exc
            if time.monotonic() >= deadline:
                break
            time.sleep(OPEN_RETRY_INTERVAL_SECONDS)
    alive_note = ""
    if backend_pid is not None:
        alive_note = (
            f"; backend pid {backend_pid} is "
            + ("still alive (raise OPEN_RETRY_TIMEOUT_SECONDS or investigate "
               "startup contention)" if backend_alive(backend_pid)
               else "no longer running (it exited/crashed before ever "
               "binding -- this is not a timing race, look at its own "
               "stderr output above)")
        )
    print(
        f"{LABEL} UART open failed after {attempt} attempts over "
        f"{OPEN_RETRY_TIMEOUT_SECONDS}s{alive_note}",
        file=sys.stderr,
        flush=True,
    )
    raise last_error
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
    (b"usb msc: ready", "USB mass-storage ready"),
    (b"usb ext2: provisioned", "USB ext2 provision"),
    (b"usb ext2: mounted", "USB ext2 mount"),
    (b"ext2 mount:", "ext2 mount"),
    (b"rootfs image:", "rootfs image resolve"),
    (b"persistent shell: uart blocked", "ash readiness"),
    (b"interactive shell: uart blocked", "ash readiness"),
)


def ash_ready(output: bytes) -> bool:
    return any(marker in output for marker in READY_MARKERS)


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
                    self.pending = (self.pending + data)[-READY_MARKER_WINDOW:]
                    if ash_ready(self.pending):
                        elapsed_ms = (time.time_ns() - self.launch_ns) / 1_000_000
                        print(
                            f"{LABEL} ash readiness: {elapsed_ms:.1f} ms "
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
            # socket:// transports do not implement cancel_read(). During
            # normal shutdown the main thread closes the socket to wake this
            # select(); that expected exception must not turn cleanup into a
            # traceback or leave the reader state looking live.
            if self.alive:
                self.alive = False
                self.console.cancel()
                raise


def main() -> int:
    port = sys.argv[1]
    baudrate = int(sys.argv[2])
    launch_ns = int(os.environ["KERNEL_SHELL_LAUNCH_NS"])
    serial_instance = serial.serial_for_url(port, baudrate, do_not_open=True)
    open_with_retry(serial_instance)
    connected_ms = (time.time_ns() - launch_ns) / 1_000_000
    print(
        f"{LABEL} UART connected: {connected_ms:.1f} ms after launch",
        file=sys.stderr,
        flush=True,
    )
    if os.environ.get("KERNEL_SHELL_MEASURE_ONLY") == "1":
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
                            f"{LABEL} {phase}: {elapsed_ms:.1f} ms",
                            file=sys.stderr,
                            flush=True,
                        )
                        reported_phases.add(phase)
            pending = (pending + data)[-READY_MARKER_WINDOW:]
            if ash_ready(pending):
                elapsed_ms = (time.time_ns() - launch_ns) / 1_000_000
                if "ash readiness" not in reported_phases:
                    print(
                        f"{LABEL} ash readiness: {elapsed_ms:.1f} ms "
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
        terminal.close()
        # Miniterm's join() waits for the receiver thread, but pyserial's
        # socket:// backend has no cancel_read() and its reader may be blocked
        # in select(). Closing the socket above is sufficient; the reader is
        # a daemon thread and the shutdown path must not wait forever for it.
        terminal.join(True)
        terminal.console.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
