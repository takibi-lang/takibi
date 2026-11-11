# TCP frame guard cost

The TCP frame Place exchange uses the counted short TaskMutex path. The
guard carries a linear `PreemptOff[0]`, so the compiler checks blocking
calls while the span is live. The mutex index, rank 30, and the prohibition
on handler access still protect the same frame Places.

## Linked images and static frames

Both normal kernels were built against baseline `4e04b15a` with the same
build inputs, including the RPi5 embedded image. These are linked-image
and static-frame measurements.

| Target | Text before / after (B) | Data (B) | BSS (B) | Usable RAM start |
| --- | ---: | ---: | ---: | --- |
| QEMU | 823144 / 823176 | 4608 | 1314816 | `0x40210000` |
| RPi5 | 4210788 / 4210820 | 5584 | 1925120 | `0x7e0000` |

Data and BSS symbol sizes match on each target. The guard has one member
at offset zero and occupies eight bytes in both builds. The frame Places,
TaskMutex storage, and allocation calls are unchanged.

| Function, both targets | Symbol bytes before / after | Static frame before / after (B) |
| --- | ---: | ---: |
| `tcp_frame_lock` | 24 / 48 | 16 / 32 |
| `tcp_frame_unlock` | 24 / 40 | 16 / 16 |
| `tcp_connection_frames_acquire` | 260 / 260 | 64 / 64 |
| `tcp_connection_frames_release` | 116 / 116 | 48 / 48 |
| `tcp_connection_frame_hold` | 100 / 100 | 48 / 48 |
| `tcp_connection_frame_unhold` | 116 / 116 | 48 / 48 |

The linked acquire calls the preemption-count increment before the short
acquire. The linked give calls the physical release before the decrement.
The acquire preserves the mutex argument across the added count call. Its
frame grows by 16 bytes; the give uses the same frame and adds the count
call and existing underflow-check path. The 32-byte net image cost includes
linker alignment. These measurements do not cover physical hold time, spin
latency, or full call-path stack use.
