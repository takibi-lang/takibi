# Multicore load beside Linux

A dated series, appended by `make load-qemu` and `make hwcheck-load-rpi5`
(`scripts/run_kernel_load.py --record`): one table per program, the same
program, build and arguments under Takibi and under Linux on the same machine
(#1158). The Linux column is a reference, never a verdict, and the load is a
finder, never the evidence a defect is fixed. Time verdicts are the RPi5's; QEMU
times are recorded only, and measure the host. Wall time comes from the host
clock between a phase's begin and end lines; a Linux transcript from the board
carries no wall time, only the programs' own numbers.

## 2026-10-31 qemu

Takibi commit 519bb93b; sample clean.
Linux: 6.12.0-061200-generic.
Arguments: seconds=10 jobs=64 loops=200.

### BusyBox xargs -P 4

| | Takibi | Linux |
| --- | ---: | ---: |
| status | 0 | 0 |
| wall s (host clock) | 63.70 | 1.67 |
| bogo-ops | - | - |
| ops/s real | - | - |
| ops/s usr+sys | - | - |
| reported s | - | - |

### stress-ng --fork 4

| | Takibi | Linux |
| --- | ---: | ---: |
| status | 0 | 0 |
| wall s (host clock) | 13.56 | 10.17 |
| bogo-ops | 17 | 4987 |
| ops/s real | 1.73 | 498.57 |
| ops/s usr+sys | 0.00 | 126.12 |
| reported s | - | - |

### stress-ng --exec 4

Takibi waits for #1190: stress-ng's exec stressor skips with "can't determine stress-ng executable name" -- readlinkat (nr 78) of /proc/self/exe is unimplemented.

| | Takibi | Linux |
| --- | ---: | ---: |
| status | not run | 0 |
| wall s (host clock) | not run | 10.13 |
| bogo-ops | not run | 2489 |
| ops/s real | not run | 248.27 |
| ops/s usr+sys | not run | 63.70 |
| reported s | not run | - |

### stress-ng --pipe 4

| | Takibi | Linux |
| --- | ---: | ---: |
| status | 0 | 0 |
| wall s (host clock) | 13.69 | 10.12 |
| bogo-ops | 5535 | 343658 |
| ops/s real | 600.18 | 34326.80 |
| ops/s usr+sys | 0.00 | 8576.49 |
| reported s | - | - |

### hackbench -P -p -g 4

| | Takibi | Linux |
| --- | ---: | ---: |
| status | 0 | 0 |
| wall s (host clock) | 197.09 | 6.96 |
| bogo-ops | - | - |
| ops/s real | - | - |
| ops/s usr+sys | - | - |
| reported s | 185.936 | 6.756 |

## 2026-11-01 qemu

Takibi commit 222ed27d; sample clean.
Linux: 6.12.0-061200-generic.
Arguments: seconds=10 jobs=64 loops=200.

### BusyBox xargs -P 4

| | Takibi | Linux |
| --- | ---: | ---: |
| status | 0 | 0 |
| wall s (host clock) | 53.81 | 1.86 |
| bogo-ops | - | - |
| ops/s real | - | - |
| ops/s usr+sys | - | - |
| reported s | - | - |

### stress-ng --fork 4

| | Takibi | Linux |
| --- | ---: | ---: |
| status | 0 | 0 |
| wall s (host clock) | 12.51 | 10.20 |
| bogo-ops | 49 | 3817 |
| ops/s real | 4.94 | 381.20 |
| ops/s usr+sys | 7.26 | 97.13 |
| reported s | - | - |

### stress-ng --exec 4

Takibi waits for #1190: stress-ng's exec stressor skips with "can't determine stress-ng executable name" -- readlinkat (nr 78) of /proc/self/exe is unimplemented.

| | Takibi | Linux |
| --- | ---: | ---: |
| status | not run | 0 |
| wall s (host clock) | not run | 10.39 |
| bogo-ops | not run | 1321 |
| ops/s real | not run | 131.79 |
| ops/s usr+sys | not run | 34.49 |
| reported s | not run | - |

### stress-ng --pipe 4

| | Takibi | Linux |
| --- | ---: | ---: |
| status | 0 | 0 |
| wall s (host clock) | 11.92 | 10.15 |
| bogo-ops | 11805 | 309368 |
| ops/s real | 1233.80 | 30900.65 |
| ops/s usr+sys | 349.13 | 7720.28 |
| reported s | - | - |

### hackbench -P -p -g 4

| | Takibi | Linux |
| --- | ---: | ---: |
| status | 0 | 0 |
| wall s (host clock) | 197.74 | 6.98 |
| bogo-ops | - | - |
| ops/s real | - | - |
| ops/s usr+sys | - | - |
| reported s | 188.920 | 6.770 |

