# Pipe wrap fixture space

The kernel-only EL0 probe keeps 1024 bytes queued between two writes. The
second write and the final read each straddle the 4096-byte pipe ring
boundary. The final read checks the three byte patterns in order and the
eight destination bytes on each side. Existing pipe limits and allocation
workload are unchanged. The probe uses the ordinary pipe API and closes
both ends.

| Boundary | Published baseline | With probe |
| --- | ---: | ---: |
| EL0 payload .text (bytes) | 36292 | 37284 |
| Initial EL0 entry frame (bytes) | 7392 | 7392 |
| Compressed ext2 fixture (bytes) | 3336044 | 3336459 |
| Normal QEMU linked text (bytes) | 834484 | 834484 |
| Normal RPi5 linked text (bytes) | 4227680 | 4228096 |
| Normal RPi5 linked data (bytes) | 5600 | 5600 |
| Normal RPi5 linked BSS (bytes) | 1908736 | 1908736 |

The baseline is the published getrusage fixture. The added probe's static
frame is 3168 bytes and includes its reusable user buffer. The linked
kernel sizes include read-only data, including the RPi5 fixture disk.
The QEMU and RPi5 usable RAM starts remain 0x40210000 and 0x7e0000.
These are linked-space and frame measurements rather than measurements
of peak runtime call-chain occupancy.
