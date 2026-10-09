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
#   4 image record, 5 fd context, 6 address-space backing record,
#   7 the copy-on-write copy behind a read(2) store.
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
    # Only this core's kernel stack run: the region_pools (#672) grow
    # through page_alloc_contiguous too (owner PoolChunk), and a reused
    # spare run means alloc_finish asks for no stack at all on some boots,
    # which forced the address-space backing's chunk instead.
    # PageOwnerTag::KernelStack is 5.
    set $alloc_thread = $_thread
    break page_alloc_contiguous thread $alloc_thread if (int)owner == 5
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
      set $alloc_thread = $_thread
      break page_alloc thread $alloc_thread
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
        # #672: the record's pool is a built-in region_pool; its ensure
        # answers a bool, forced false on this core's first call.
        set $alloc_thread = $_thread
        break process_image_record_ensure thread $alloc_thread
        continue
        delete
        return (unsigned char)0
        printf "takibi-force-variant-return: bool false via registers\n"
        printf "alloc-rollback: forced point=image-record\n"
      else
        if $alloc_rollback_point == 5
          break scheduled_process_alloc_finish
          continue
          delete
          # #672: the context pool is a built-in region_pool; its ensure
          # answers a bool, forced false on this core's first call.
          set $alloc_thread = $_thread
          break unified_fd_context_ensure thread $alloc_thread
          continue
          delete
          return (unsigned char)0
          printf "takibi-force-variant-return: bool false via registers\n"
          printf "alloc-rollback: forced point=fd-context\n"
        else
          if $alloc_rollback_point == 6
            # #672: the backing record's pool grows through the page
            # allocator, and a refused backing used to be built into as if
            # it existed. Fail the record itself: since #693 step 5,
            # address_space_ensure_root allocates it before allocate_root,
            # and the answer is a variant whose Missing has no payload.
            break scheduled_process_alloc_finish
            continue
            delete
            set $alloc_thread = $_thread
            break address_space_ensure_root thread $alloc_thread
            continue
            delete
            # Stop before the prologue can reuse the incoming x8 result buffer.
            eval "break *%p thread %d", &address_space_backing_ensure, $alloc_thread
            continue
            delete
            takibi-force-variant-return AddressSpaceBackingReady Missing
            printf "alloc-rollback: forced point=address-space-backing\n"
          else
            if $alloc_rollback_point == 7
              # #725: the private copy of a shared copy-on-write page that
              # read(2) is about to store into. The probe shares the page
              # with a sibling address space, so the resolve takes its
              # allocating path; fail that allocation once.
              break kernel_syscall_cow_read_probe
              continue
              delete
              set $alloc_thread = $_thread
              break address_space_resolve_cow thread $alloc_thread
              continue
              delete
              break page_alloc thread $alloc_thread
              continue
              delete
              takibi-force-variant-return PageAllocResult OutOfMemory
              printf "alloc-rollback: forced point=cow-read\n"
            else
              error "unknown alloc-rollback point; expected 1 through 7"
            end
          end
        end
      end
    end
  end
end

# gdb-multiarch's batch mode detaches when the command list ends, and an
# automatic detach resumes a target stopped at the breakpoint. There is
# deliberately no trailing continue.
