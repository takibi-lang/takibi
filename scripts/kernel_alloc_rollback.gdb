# GitHub issue #414: fail exactly one acquisition inside
# scheduled_process_alloc's chain, from the debugger side, and let the
# kernel's own rollback run.
#
# The poke is the page allocator's free-list head, which is what issue #414
# proposed. kernel/lib/freelist.tkb's freelist_core_insert treats any head
# outside [0, runtime_page_count) as an empty list, so writing the discovered
# count makes every page_alloc report OutOfMemory without touching a single
# page's metadata -- nothing to undo afterwards but the head itself.
#
# Which acquisition fails is chosen by WHERE this arms, not by the poke:
# address_space_allocate_root is past the process record and the kernel
# stack run, so the rollback under test is the interesting one -- it has to
# give back the record, park the stack run, and release the address-space
# backing record that address_space_ensure_root already took before the
# pages failed.
#
# **It arms inside the boot suite's measured window, and on a victim the
# run survives.** Two things have to hold at once. The pooled-record
# baseline (kernel/init/test_driver.tkb) has to be taken BEFORE the injected
# failure, or the leak lands in the baseline itself and the end-of-run
# comparison can never see it -- not a theory: armed at the first hit of the
# boot, deleting a rollback step still passed this lane. And the process
# creation that gets refused has to belong to something that reports and
# carries on; refusing ash's first fork ends the init script, and a run that
# stops has no accounting to check. kernel_test_common_probes is the first
# call after the baseline and the probes are exactly that kind of victim --
# scheduled_process_table_probe logs "process table: failed" and the boot
# continues.
#
# The restore point is kernel_boot_log_resource_exhausted, which the failing
# arm calls BEFORE it rolls anything back. Restoring there means the
# rollback itself, and every later allocation in the boot, runs against a
# healthy allocator -- so this lane injects one failure rather than
# poisoning the run.
#
# The three stops are a flat command list, not breakpoint `commands` blocks:
# a memory read inside a `commands` block that follows a nested `continue`
# fails against this target with "Cannot execute this command while the
# target is running", even though the target is stopped at a breakpoint.
# The same read at the top level, after a top-level `continue`, works --
# which is the shape scripts/run_kernel_qemutest_lifecycle_gap.sh already
# uses. Each breakpoint is deleted once it has done its job, so exactly one
# allocation fails however many processes the boot goes on to create.
#
# There is deliberately no trailing `continue`: gdb-multiarch's batch mode
# detaches when the command list ends, and an automatic detach resumes a
# target stopped at a breakpoint. Nothing needs the debugger after the
# restore.
set confirm off
set pagination off
break kernel_test_common_probes
continue
delete
printf "alloc-rollback: armed after the pooled-record baseline\n"
break address_space_allocate_root
continue
set $saved_free_head = boot_page_pool.runtime_free_head
set boot_page_pool.runtime_free_head = boot_page_pool.runtime_page_count
delete
printf "alloc-rollback: injected at address_space_allocate_root, saved_free_head=%lu\n", $saved_free_head
break kernel_boot_log_resource_exhausted
continue
set boot_page_pool.runtime_free_head = $saved_free_head
delete
printf "alloc-rollback: restored free_head=%lu\n", boot_page_pool.runtime_free_head
