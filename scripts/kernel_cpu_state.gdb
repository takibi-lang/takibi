# GitHub issue #1366: every CPU's architectural state on a stopped QEMU, for
# a stall capture taken before the serial BREAK changes it. Registers only,
# never guest memory, so it answers even when the kernel's own structures are
# the thing that is wrong, and when the BREAK then reaches no debugger (a
# CPU spinning with IRQs masked) this is the only record of where it was.
# Usage: source scripts/kernel_cpu_state.gdb; takibi-cpus
python
import gdb


TAKIBI_CPU_REGISTERS = ("pc", "sp", "cpsr", "ELR_EL1", "ESR_EL1", "FAR_EL1",
                        "SPSR_EL1", "DAIF", "SP_EL0", "TTBR0_EL1",
                        "MPIDR_EL1")


class TakibiCpus(gdb.Command):
    def __init__(self):
        super().__init__("takibi-cpus", gdb.COMMAND_STATUS)

    def invoke(self, argument, from_tty):
        if argument.strip():
            raise gdb.GdbError("usage: takibi-cpus")
        selected = gdb.selected_thread()
        threads = sorted(gdb.selected_inferior().threads(),
                         key=lambda thread: thread.num)
        if not threads:
            raise gdb.GdbError("takibi-cpus: no CPU threads")
        try:
            for thread in threads:
                if not thread.is_stopped():
                    gdb.write(f"takibi-cpus: thread={thread.num} running\n")
                    continue
                thread.switch()
                fields = []
                for name in TAKIBI_CPU_REGISTERS:
                    try:
                        value = int(gdb.parse_and_eval("$" + name)) & (2**64 - 1)
                        fields.append(f"{name.lower()}=0x{value:x}")
                    except (gdb.error, ValueError):
                        fields.append(f"{name.lower()}=unavailable")
                gdb.write(f"takibi-cpus: thread={thread.num} "
                          + " ".join(fields) + "\n")
                for name in ("pc", "ELR_EL1"):
                    try:
                        where = gdb.execute(f"info symbol ${name}",
                                            to_string=True).strip()
                    except gdb.error as error:
                        where = f"unavailable: {error}"
                    gdb.write(f"takibi-cpus: thread={thread.num} "
                              f"{name.lower()}-symbol {where}\n")
        finally:
            if selected is not None:
                selected.switch()
        gdb.write(f"takibi-cpus: complete threads={len(threads)}\n")


TakibiCpus()
end
