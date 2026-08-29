# Source after loading kernel/build/qemu/kernel-debug.elf.  takibi-pages is
# read-only: it summarizes the DT-derived allocator layout and checks the
# invariants most useful when boot stops during page-pool initialization.

define takibi-pages
  if boot_page_pool.runtime_applied == 0
    printf "pages: runtime memory description has not been applied\n"
  else
    set $count = boot_page_pool.runtime_page_count
    set $extent_count = boot_page_pool.runtime_extent_count
    set $meta = boot_page_pool.runtime_meta_base
    set $extents = boot_page_pool.runtime_extent_base
    set $free = boot_page_pool.runtime_free_head
    set $ok = 1
    printf "pages: count=%lu extents=%lu meta=0x%lx extent_table=0x%lx free_head=%lu\n", $count, $extent_count, $meta, $extents, $free

    if ($meta & 15) != 0
      printf "  FAIL: PageMeta base is not 16-byte aligned\n"
      set $ok = 0
    end
    if $extents != $meta + $count * sizeof(boot_page_pool.meta[0])
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
      # PageExtent is three usize fields.  LLVM omits its standalone DWARF
      # type because no typed global retains it, so inspect the table in its
      # actual ABI representation instead of depending on a missing name.
      set $extent = ((usize *) $extents) + $i * 3
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
