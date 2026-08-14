# Read-only GDB command for an EL1 fail-stop record.
# Usage: source scripts/kernel_crash_snapshot.gdb; takibi-oops
#
# Takibi currently emits no DWARF type for this global. Source the compiler-
# generated _build/kernel-crash-snapshot-layout.gdb first; this command then
# reads CrashSnapshot through those target-layout offsets. It deliberately
# does not duplicate any ExceptionFrame or CrashSnapshot offsets.
define takibi-oops
  set $snapshot = (unsigned long *)&crash_snapshot
  if $snapshot[$takibi_crashsnapshot_valid / 8] == 0
    printf "takibi-oops: no valid crash snapshot\n"
  else
    printf "takibi-oops: seq=%lu cpu=%lu slot=%lu esr=0x%016lx far=0x%016lx elr=0x%016lx spsr=0x%016lx\n", $snapshot[$takibi_crashsnapshot_sequence / 8], $snapshot[$takibi_crashsnapshot_cpu / 8], $snapshot[$takibi_crashsnapshot_vector_slot / 8], $snapshot[$takibi_crashsnapshot_esr_el1 / 8], $snapshot[$takibi_crashsnapshot_far_el1 / 8], $snapshot[$takibi_crashsnapshot_elr_el1 / 8], $snapshot[$takibi_crashsnapshot_spsr_el1 / 8]
    printf "takibi-oops: live sp_el0=0x%016lx tpidr_el0=0x%016lx ttbr0=0x%016lx\n", $snapshot[$takibi_crashsnapshot_sp_el0 / 8], $snapshot[$takibi_crashsnapshot_tpidr_el0 / 8], $snapshot[$takibi_crashsnapshot_ttbr0_el1 / 8]
    printf "takibi-oops: process pid=%lu parent=%lu state=%lu wait=%lu root=%lu asid=%lu image=%lu\n", $snapshot[$takibi_crashsnapshot_process_pid / 8], $snapshot[$takibi_crashsnapshot_parent_pid / 8], $snapshot[$takibi_crashsnapshot_process_state / 8], $snapshot[$takibi_crashsnapshot_wait_reason / 8], $snapshot[$takibi_crashsnapshot_root_slot / 8], $snapshot[$takibi_crashsnapshot_root_asid / 8], $snapshot[$takibi_crashsnapshot_image_kind / 8]
    printf "takibi-oops: wait4_status_ptr=0x%016lx\n", $snapshot[$takibi_crashsnapshot_wait4_status_ptr / 8]
    set $fd_item = 0
    while $fd_item < 16
      if $snapshot[$takibi_crashsnapshot_fd_kind / 8 + $fd_item] != 0
        printf "takibi-oops: fd=%lu kind=%lu object=%lu\n", $fd_item, $snapshot[$takibi_crashsnapshot_fd_kind / 8 + $fd_item], $snapshot[$takibi_crashsnapshot_fd_object / 8 + $fd_item]
      end
      set $fd_item = $fd_item + 1
    end
    if $snapshot[$takibi_crashsnapshot_saved_frame_available / 8] != 0
      printf "takibi-oops: saved sp_el0=0x%016lx tpidr_el0=0x%016lx elr=0x%016lx spsr=0x%016lx\n", $snapshot[$takibi_crashsnapshot_saved_sp_el0 / 8], $snapshot[$takibi_crashsnapshot_saved_tpidr_el0 / 8], $snapshot[$takibi_crashsnapshot_saved_elr_el1 / 8], $snapshot[$takibi_crashsnapshot_saved_spsr_el1 / 8]
    else
      printf "takibi-oops: saved-frame=unavailable\n"
    end
    printf "takibi-oops: trace count=%lu\n", $snapshot[$takibi_crashsnapshot_trace_count / 8]
    set $trace_item = 0
    while $trace_item < $snapshot[$takibi_crashsnapshot_trace_count / 8]
      set $trace_base = $trace_item * 12
      printf "takibi-oops: trace seq=%lu cpu=%lu event=%lu pid=%lu gen=%lu peer=%lu peer-gen=%lu state=%lu wait=%lu root=%lu sp=0x%016lx aux=0x%016lx\n", $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 1], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 2], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 3], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 4], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 5], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 6], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 7], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 8], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 9], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 10], $snapshot[$takibi_crashsnapshot_trace / 8 + $trace_base + 11]
      set $trace_item = $trace_item + 1
    end
  end
end

document takibi-oops
Print the kernel's retained CrashSnapshot through its DWARF type.
end
