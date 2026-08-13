# Read-only GDB command for an EL1 fail-stop record.
# Usage: source scripts/kernel_crash_snapshot.gdb; takibi-oops
#
# Takibi currently emits no DWARF type for this global, so this command reads
# the fixed CrashSnapshot word record. It deliberately does not duplicate any
# ExceptionFrame offsets: the kernel has already copied diagnostic fields into
# crash_snapshot before it parks the CPU.
define takibi-oops
  set $snapshot = (unsigned long *)&crash_snapshot
  if $snapshot[0] == 0
    printf "takibi-oops: no valid crash snapshot\n"
  else
    printf "takibi-oops: seq=%lu cpu=%lu slot=%lu esr=0x%016lx far=0x%016lx elr=0x%016lx spsr=0x%016lx\n", $snapshot[1], $snapshot[2], $snapshot[3], $snapshot[4], $snapshot[5], $snapshot[6], $snapshot[7]
    printf "takibi-oops: live sp_el0=0x%016lx tpidr_el0=0x%016lx ttbr0=0x%016lx\n", $snapshot[8], $snapshot[9], $snapshot[10]
    printf "takibi-oops: process pid=%lu parent=%lu state=%lu wait=%lu root=%lu asid=%lu image=%lu\n", $snapshot[11], $snapshot[12], $snapshot[13], $snapshot[14], $snapshot[15], $snapshot[17], $snapshot[18]
    if $snapshot[19] != 0
      printf "takibi-oops: saved sp_el0=0x%016lx tpidr_el0=0x%016lx elr=0x%016lx spsr=0x%016lx\n", $snapshot[20], $snapshot[23], $snapshot[21], $snapshot[22]
    else
      printf "takibi-oops: saved-frame=unavailable\n"
    end
    printf "takibi-oops: trace count=%lu\n", $snapshot[24]
    set $trace_item = 0
    while $trace_item < $snapshot[24]
      set $trace_base = $trace_item * 3
      printf "takibi-oops: trace event=%lu from=%lu to=%lu\n", $snapshot[25 + $trace_base], $snapshot[26 + $trace_base], $snapshot[27 + $trace_base]
      set $trace_item = $trace_item + 1
    end
  end
end

document takibi-oops
Print the kernel's retained CrashSnapshot through its DWARF type.
end
