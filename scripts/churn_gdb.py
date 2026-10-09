"""Bounded GDB operations for the QEMU churn runner; QMP is never held open."""

from pathlib import Path
import subprocess
import tempfile

from capture_kernel_console import qmp


class ChurnGdb:
    def __init__(self, artifact, elf):
        self.artifact = Path(artifact)
        self.elf = Path(elf)
        self.qmp_socket = self.artifact / "qmp.sock"
        self.directory = None
        self.endpoint = None

    def open(self):
        self.directory = tempfile.TemporaryDirectory(prefix="tk-churn-")
        self.endpoint = str(Path(self.directory.name) / "gdb")
        try:
            reply = qmp(self.qmp_socket, "human-monitor-command", {
                "command-line": f"gdbserver unix:{self.endpoint},server=on,wait=off"})
            if not Path(self.endpoint).is_socket():
                raise RuntimeError("cannot open churn GDB stub: " + reply.strip())
        except Exception:
            self.directory.cleanup()
            self.directory = None
            self.endpoint = None
            raise

    def close(self):
        if self.directory is not None:
            try:
                qmp(self.qmp_socket, "human-monitor-command", {"command-line": "gdbserver none"})
            finally:
                self.directory.cleanup()
                self.directory = None
                self.endpoint = None

    def run(self, next_asid=None):
        repo = Path(__file__).resolve().parent.parent
        output = self.artifact / ("asid-jump.log" if next_asid is not None else "gdb-stall.log")
        with output.open("a", encoding="ascii") as stream:
            stream.write(f"ELF: {self.elf.resolve()}\n")
            stream.flush()
            was_running = None
            try:
                was_running = qmp(self.qmp_socket, "query-status")["running"]
                command = f"takibi-churn {repo}/_build/kernel-churn-layout.gdb"
                if next_asid is not None:
                    command += f" {next_asid}"
                argv = ["gdb-multiarch", "-nx", "-q", "-batch", str(self.elf)]
                for instruction in ("set pagination off", "set remotetimeout 2",
                                    f"target remote {self.endpoint}",
                                    f"source {repo}/scripts/kernel_churn.gdb", command, "disconnect"):
                    argv.extend(["-ex", instruction])
                result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        timeout=10, text=True, encoding="ascii", errors="replace")
                stream.write(result.stdout)
                marker = "churn ASID jump complete:" if next_asid is not None else "churn stall dump complete"
                if result.returncode or marker not in result.stdout:
                    if next_asid is not None and not result.returncode and "churn ASID jump deferred: lock held" in result.stdout:
                        return False
                    raise RuntimeError(f"GDB did not complete churn operation (status {result.returncode})")
                return True
            except Exception as error:
                stream.write(f"churn GDB unavailable: {error}\n")
                raise
            finally:
                if was_running is not None:
                    qmp(self.qmp_socket, "cont" if was_running else "stop")
