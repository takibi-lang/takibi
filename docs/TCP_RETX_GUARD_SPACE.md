# TCP retransmit guard cost

The retransmit chain and retry-state lock retains a counted preemption span
in its existing indexed RetxGuard. The span begins before the short acquire
and ends after physical unlock. Blocking is rejected while the guard is live.
The mutex identity, rank 30 and handler prohibition remain checked.

## Measurement boundary

The baseline is published be0d0601. All four complete normal/debug closures
were compiled with the maintained QEMU and RPi5 arguments, including unused
checks. The paired baseline restores that commit's TCP source; all other
sources, toolchain, embedded image, assembly objects and linker inputs match.
The maintained link commands link each resulting object. Debug compiles add
`-g` to the same target arguments. These are
linked-image and per-function static-frame observations.

| Target | Text before / after (B) | Data (B) | BSS (B) | Usable RAM start |
| --- | ---: | ---: | ---: | --- |
| QEMU normal | 828112 / 828144 | 4616 | 1314816 | `0x40210000` |
| QEMU debug | 905380 / 905420 | 4616 | 1314816 | `0x40228000` |
| RPi5 normal | 4215820 / 4215852 | 5592 | 1921024 | `0x7e0000` |
| RPi5 debug | 4301968 / 4302008 | 5592 | 1839104 | `0x7e0000` |

Every data/BSS symbol retains its size. RetxGuard retains one eight-byte
member at offset zero. The chain, entries, pools and allocation inputs retain
their representation. Adopt the measured 32-byte normal and 40-byte debug
text cost on each target. Data, BSS and reservation comparisons are within
each mode; normal and debug have different image boundaries.

| Function and mode, both targets | Symbol bytes before / after | Static frame before / after (B) |
| --- | ---: | ---: |
| `retx_lock`, normal | 24 / 48 | 16 / 32 |
| `retx_lock`, debug | 40 / 64 | 32 / 48 |
| `retx_unlock`, normal | 24 / 40 | 16 / 16 |
| `retx_unlock`, debug | 44 / 60 | 32 / 48 |

All seven direct callers retain their own symbol and static-frame sizes
in all four modes.
The compiled graph records twelve named held sites, comprising seven gives,
four retry copies and one counter read. The rest of each scope contains
Place exchanges, local arithmetic and branching. Cleanup and transmission
occur after the guard is released.

Linked disassembly shows the count increment before short acquire and the
physical release before decrement. The acquire preserves its mutex argument
across the count call. Its static frame grows by sixteen bytes in both
modes; the debug unlock frame also grows by sixteen bytes. The existing
count-underflow invariant check remains in the span-end path. Linker
alignment accounts for the net text delta. Physical hold time, spin latency
and full call-path stack use require separate measurements.
