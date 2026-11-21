# Scalar ABI tail fixture space

Both normal kernels were compared with `0a36c6b20`. The existing EL0
fixture now checks the statfs reserved tail and the sysinfo output tail
and extent during successful calls. The kernel syscall handlers and
allocation workload are unchanged.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Linked text (bytes) | 832252 | 832252 | 4225800 | 4225720 |
| Linked data (bytes) | 4624 | 4624 | 5600 | 5600 |
| Linked BSS (bytes) | 1310720 | 1310720 | 1908736 | 1908736 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The normal QEMU kernel ELF is byte-identical. The EL0 payload text grows
480 bytes and the compressed fixture image embedded in the RPi5 kernel
shrinks from 3336226 to 3336157 bytes. RPi5 linked text accounting
includes that image and linker alignment. The existing statfs probe's
static frame grows from 288 to 304 bytes, the sysinfo probe has a
160-byte frame, and the calling EL0 entry frame remains 7376 bytes.
Individual frames do not measure a call-chain maximum. Physical timing
was outside this review.

## getrusage fixture

The kernel-only EL0 probe initializes a 160-byte array before passing its
144-byte interior to `getrusage(RUSAGE_SELF)`. It checks the 112 zero
bytes after the timevals and the eight unchanged bytes on each side.
The standalone host Linux fixture keeps its existing checks because
Linux may account nonzero fields in that tail.

Compared with `ab24e7bb5`, the linked EL0 `.text` grows from 35972 to
36292 bytes. The new probe's static frame is 192 bytes and the initial
payload frame stays 7392 bytes. No writable user payload storage is
added. The compressed ext2 fixture grows from 3335873 to 3336044 bytes.
The QEMU kernel's linked `.text`, `.rodata` and `.data` bytes are
unchanged. RPi5's embedded image changes the linked read-only contents,
including a 160-byte increase in `.rodata`. The aggregate linked text
accounting stays 834484 bytes on QEMU and increases from 4227520 to
4227680 bytes on RPi5. The usable RAM starts remain `0x40210000` and
`0x7e0000`, respectively. The kernel syscall and allocation workload are
unchanged.
