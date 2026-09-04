# GitHub issue #414: fail exactly one acquisition inside
# scheduled_process_alloc's chain, from the debugger side, and let the
# kernel's own rollback run.
#
# GitHub issue #425 made the compiler's AArch64 variant-return convention
# available to GDB. The injection can therefore return
# PageRunAllocResult::OutOfMemory directly instead of corrupting the
# page allocator temporarily. The helper validates the compiler-owned case
# tag and return location before changing registers.
#
# Which acquisition fails is chosen by WHERE this arms:
# scheduled_process_alloc_finish is past the process-record acquisition.
# Its first page_alloc_contiguous call asks for the kernel stack run, one of
# issue #425's four failure points that the old free-list poke could not
# cover. The rollback has to give the process record back without leaking
# pages or freeing anything twice.
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
# forced return.
set confirm off
set pagination off
break kernel_test_common_probes
continue
delete
printf "alloc-rollback: armed after the pooled-record baseline\n"
break scheduled_process_alloc_finish
continue
delete
break page_alloc_contiguous
continue
delete
takibi-force-variant-return PageRunAllocResult OutOfMemory
printf "alloc-rollback: forced PageRunAllocResult::OutOfMemory\n"
