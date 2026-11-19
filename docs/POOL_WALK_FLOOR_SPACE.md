# Pool walk floor storage and linked code

The pool walk fixture publishes the permanent floor's address through an
AtomicWord. The floor record stays Held for the boot. Peers still obtain a
fresh Held reference and read the stamp under the same pool guard. The ready
flag, round publication, stale-reference check, and peer teardown keep their
existing roles.

Both normal linked kernels were compared against `8bac2590d`. Sizes are
in bytes.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text | 831876 | 831892 | 4225504 | 4225504 |
| Data | 4624 | 4624 | 5600 | 5600 |
| BSS | 1310720 | 1310720 | 1912832 | 1912832 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The floor symbol shrinks from 16 to 8 bytes on both targets. The linked
walk loop uses one acquire load for the comparison that previously read a
pair and called the address accessor. The linked walker sizes stay 652
bytes on QEMU and 552 on RPi5. The walker frame shrinks from 128 to 112
bytes on QEMU and stays 128 bytes on RPi5. Both debug walker frames stay
160 bytes. The QEMU initializer grows by 12 instruction bytes. The pool chunk and the floor slot retention are
unchanged. Acquire latency was outside this review.
