# Source after loading kernel/build/qemu/kernel-debug.elf.  takibi-pages is
# read-only: it summarizes the DT-derived allocator layout and checks the
# invariants most useful when boot stops during page-pool initialization.
#
# Layout (GitHub issue #744): the pool is the value of boot_page_pool_cell
# (a LockedCell keeps its value first), and the PageMeta and PageExtent
# tables are regions held in page_meta_store's two places. A Place of a
# region is three words: the tag (1 = Full), the region's address and its
# element count.

define takibi-pages
  set $pool = boot_page_pool_cell.value
  if $pool.runtime_applied == 0
    printf "pages: runtime memory description has not been applied\n"
  else
    set $count = $pool.runtime_page_count
    set $extent_count = $pool.runtime_extent_count
    set $store = (unsigned long *) &page_meta_store
    set $meta_full = $store[0]
    set $meta = $store[1]
    set $meta_len = $store[2]
    set $extent_full = $store[3]
    set $extents = $store[4]
    set $extent_len = $store[5]
    set $free = $pool.runtime_free_head
    set $ok = 1
    printf "pages: count=%lu extents=%lu meta=0x%lx extent_table=0x%lx free_head=%lu\n", $count, $extent_count, $meta, $extents, $free

    if $meta_full != 1 || $extent_full != 1
      printf "  FAIL: a metadata place is not Full (meta=%lu extents=%lu)\n", $meta_full, $extent_full
      set $ok = 0
    end
    if $meta_len != $count
      printf "  FAIL: PageMeta region holds %lu entries, expected %lu\n", $meta_len, $count
      set $ok = 0
    end
    if $extent_len < $extent_count
      printf "  FAIL: PageExtent region holds %lu entries, %lu in use\n", $extent_len, $extent_count
      set $ok = 0
    end
    if ($meta & 4095) != 0
      printf "  FAIL: PageMeta base is not page aligned\n"
      set $ok = 0
    end
    if $extents != $meta + $count * 24
      printf "  FAIL: PageExtent table does not immediately follow PageMeta array\n"
      set $ok = 0
    end
    if $free > $count
      printf "  FAIL: free_head is outside the metadata array\n"
      set $ok = 0
    end

    set $i = 0
    set $next_index = 0
    while $i < $extent_count
      # PageExtent is three usize fields.
      set $extent = ((unsigned long *) $extents) + $i * 3
      set $start = $extent[0]
      set $end = $extent[1]
      set $first = $extent[2]
      printf "  extent[%lu]: [0x%lx, 0x%lx) first_index=%lu\n", $i, $start, $end, $first
      if (($start & 4095) != 0) || (($end & 4095) != 0) || ($start >= $end)
        printf "    FAIL: invalid page-aligned half-open range\n"
        set $ok = 0
      end
      if $first != $next_index
        printf "    FAIL: expected first_index=%lu\n", $next_index
        set $ok = 0
      end
      set $next_index = $next_index + (($end - $start) / 4096)
      set $i = $i + 1
    end
    if $next_index != $count
      printf "  FAIL: extents describe %lu pages, expected %lu\n", $next_index, $count
      set $ok = 0
    end
    if $ok
      printf "  invariants: PASS\n"
    end
  end
end

document takibi-pages
Summarize the runtime physical-page allocator and validate its metadata and
extent layout.  This command does not modify target memory.
end
