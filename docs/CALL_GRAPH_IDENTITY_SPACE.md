# Call graph definition identity space

The baseline is `10257b670`. The existing compiler and the corrected
compiler took the same normal QEMU and Raspberry Pi 5 inputs and build
flags. Both normal `main.o` files and linked kernel ELFs are byte-identical.
The memory map check passes with the same five allocator expectations.

| Host compiler artifact | QEMU baseline | QEMU corrected | RPi5 baseline | RPi5 corrected |
|---|---:|---:|---:|---:|
| Call graph rows | 4740 | 5896 | 5186 | 6767 |
| Call graph bytes | 2246892 | 2443557 | 2397438 | 2665753 |
| Compiler allocation counter (words) | 804927385 | 805234420 | 897998698 | 898401033 |

The extra rows represent distinct generated definitions. Each target
retains all its source rows, with differences confined to generated
callee labels in 209 source rows. Source signatures are byte-identical.
The allocation counter is cumulative host allocation with `--facts`
enabled. It does not measure peak residency, wall time, or target memory.
