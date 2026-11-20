# Direct TCP send space

The connected write syscall copies a checked user span into the payload of
the existing TX frame. The input copy completes before TCP headers,
sequence numbers, retransmit state, or transmission are updated. A copy
fault returns the frame and reports EFAULT. The RX frame stays available
to the receive path.

The connected write path now has one payload copy from user memory to the
TX frame. Previously it copied the payload from user memory into a staging
frame and then into the TX frame. The driver and retransmission copies
retain their existing ownership and lifetime boundaries.

Compared with `b19cbe015` using the maintained linked QEMU and Raspberry Pi 5
images and LLVM's static frame sizes from their AArch64 objects.

| Measurement | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Normal text (bytes) | 834496 | 834416 | 4227532 | 4227460 |
| Debug text (bytes) | 914432 | 914104 | 4316620 | 4316516 |
| Normal data (bytes) | 4624 | 4624 | 5600 | 5600 |
| Normal BSS (bytes) | 1310720 | 1310720 | 1908736 | 1908736 |
| Normal usable RAM start | `0x40210000` | `0x40210000` | `0x7e0000` | `0x7e0000` |
| Normal write worker frame (bytes) | 272 | 240 | 112 | 80 |
| Normal TCP send frame (bytes) | 240 | 256 | 144 | 144 |
| Debug write worker frame (bytes) | 448 | 336 | 224 | 176 |
| Debug TCP send frame (bytes) | 448 | 512 | 320 | 352 |

The size of each linked writable symbol and the usable RAM start also
match in the debug images. The copy helper's static frame stays at 16 bytes
in normal builds and 96 bytes in debug builds. The frame gate covers
individual compiled functions. Execution time, whole-stack occupancy,
and physical timing are outside this measurement.

Remeasure when the send staging arrangement, TX frame storage, or the
copy and retransmission boundaries change.
