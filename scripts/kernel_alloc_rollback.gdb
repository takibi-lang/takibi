# GitHub issue #414: fail exactly one acquisition inside
# scheduled_process_alloc's chain, from the debugger side, and let the
# kernel's own rollback run.
#
# GitHub issue #425 made the compiler's AArch64 variant-return convention
# available to GDB. Each injection below returns a payload-free OutOfMemory
# case directly, so the lane never edits allocator state.
#
# $alloc_rollback_point is selected by the runner:
#   1 process record, 2 kernel stack run, 3 address-space root,
#   4 image record, 5 fd context.
#
# Every point arms after the process-pool baseline and inside the first
# process-table probe. That probe reports a failed allocation and continues,
# leaving the boot alive to produce the end-of-run accounting. Each breakpoint
# is removed after one hit so only one acquisition fails.
set confirm off
set pagination off
break kernel_test_common_probes
continue
delete
printf "alloc-rollback: armed after the pooled-record baseline\n"

if $alloc_rollback_point == 1
  break scheduled_process_alloc_pending
  continue
  delete
  break intrusive_pool_insert_zeroed$ProcessRecord
  continue
  delete
  takibi-force-variant-return IntrusivePoolInsertResult OutOfMemory
  printf "alloc-rollback: forced point=process-record\n"
else
  if $alloc_rollback_point == 2
    break scheduled_process_alloc_finish
    continue
    delete
    break page_alloc_contiguous
    continue
    delete
    takibi-force-variant-return PageRunAllocResult OutOfMemory
    printf "alloc-rollback: forced point=stack-run\n"
  else
    if $alloc_rollback_point == 3
      break scheduled_process_alloc_finish
      continue
      delete
      break address_space_allocate_root
      continue
      delete
      break page_alloc
      ignore $bpnum 1
      continue
      delete
      takibi-force-variant-return PageAllocResult OutOfMemory
      printf "alloc-rollback: forced point=address-space-root\n"
    else
      if $alloc_rollback_point == 4
        break scheduled_process_alloc_finish
        continue
        delete
        break process_image_record_ensure
        continue
        delete
        break intrusive_pool_insert_zeroed$ProcessImageRecord
        continue
        delete
        takibi-force-variant-return IntrusivePoolInsertResult OutOfMemory
        printf "alloc-rollback: forced point=image-record\n"
      else
        if $alloc_rollback_point == 5
          break scheduled_process_alloc_finish
          continue
          delete
          break unified_fd_context_ensure
          continue
          delete
          break intrusive_pool_insert_zeroed$ProcessFdContext
          continue
          delete
          takibi-force-variant-return IntrusivePoolInsertResult OutOfMemory
          printf "alloc-rollback: forced point=fd-context\n"
        else
          error "unknown alloc-rollback point; expected 1 through 5"
        end
      end
    end
  end
end

# gdb-multiarch's batch mode detaches when the command list ends, and an
# automatic detach resumes a target stopped at the breakpoint. There is
# deliberately no trailing continue.
