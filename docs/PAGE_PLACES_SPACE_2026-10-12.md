# Per-page permissions in places: space and time (2026-10-12)

GitHub issue #746. Every page not handed out keeps its permission in a
per-page place; PageOwner and PageRunOwner carry it while the page is out.

## Linked images (llvm-size, against main before #746)

| Kernel | text | data | BSS |
|---|---|---|---|
| QEMU before | 693768 | 5408 | 1658480 |
| QEMU after | 705160 (+11392) | 5424 (+16) | 1660656 (+2176) |
| RPi5 before | 706728 | 2889272 | 1697360 |
| RPi5 after | 718000 (+11272) | 2889288 (+16) | 1697360 (0) |

The BSS growth is the bootstrap pages' tag bytes (2048, one per bootstrap
page) and alignment. QEMU's usable_ram_start moved by 8 pages, which is why
the QEMU allocator page counts were refreshed; RPi5's did not move.

## Runtime metadata (per managed page and per extent)

- PageMeta stays 24 bytes (`--emit-struct-layout PageMeta`).
- One tag byte per managed page, carved with the metadata: +1 B/page, about
  4% of the 24-byte metadata and 0.024% of RAM (+256 KiB per GiB).
- One 64-byte slot per RAM extent (the slot cell measures 40 bytes,
  `--emit-struct-layout SlotsCell__PageExtentFrames`).
- No per-page region payload: a permission's address is computed from the
  extent and the index, so the naive 24 B/page form the issue rejected is
  not paid.

## Time on RPi5 (page_allocator_timing_probe, 1024 alloc/free pairs)

| Build | ticks (54 MHz) |
|---|---|
| before #744 | 3988 |
| after #744 | 4733 |
| after #746 | 13032 |

#746 makes a pair about 2.75 times as slow as after #744 (about 241 us per
1024 pairs, 235 ns a pair). Each pair now finds the extent in the extent
table, exchanges the extent's slot out and back (a guarded place exchange
copying the extent's places), and walks the tag bytes, on both alloc and
free. Recorded, not judged: no time bound is set, and the regression is
tracked with #744's on #748. Candidates there: lend the slot without the
exchange (place_borrow of an array element in its yielding form is not
supported yet), and skip the extent search when there is one extent.
