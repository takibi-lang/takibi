# Exception CPU stores and virtio-net integration space review

Measured combined candidate 0b113496 against the archived published e15c4f54
production ELFs. The JSON records each verified baseline/candidate SHA256,
source fingerprint, llvm-size sections, changed data/BSS symbols and usable RAM.
The archived baseline manifest hashes were checked before comparison.

| Platform | Text before/after | Data before/after | BSS span before/after | Image reservation change |
|---|---|---|---|---|
| QEMU | 815420 / 818056 | 4616 / 4632 | 1302528 / 1318912 | +32768 bytes, eight pages |
| RPi5 | 4200424 / 4202692 | 5592 / 5608 | 1925120 / 1937408 | unchanged within alignment |

The exception representation adds 16544 fixed payload bytes: private capture
and own-CPU read scratch coexist with the flat coherent publication mirror.
Stopped-root payload128 plus atomic sequence32 replaces160 bytes unchanged.
The net queue remains512 bytes, block queue256 and shared lock8. Net queues
are absent from the RPi5 image before and after. Combined code growth is
measured directly, rather than adding independent branch deltas.

The workload remains maintained boot/network queues, complete-stop DDB reads,
guarded fault recovery and terminal capture/console paths. No new heap, pool,
per-process allocation or retained capacity is introduced. Terminal diagnostic
storage lasts until reboot. Scratch cannot overwrite cached capture and is
per CPU because bounded report serialization can be abandoned. Preserve the
reviewed safety cost; unchanged RPi5 reservation does not make payload free.

Individual corrected frame observations and separate publication/cached-console
call paths remain documented in EXCEPTION_CPU_SPACE.md. They are not a whole
16KiB stack proof. No comparison boundary requires fresh Linux/FreeBSD numbers.
Combined kernelbuild exited0; the exact integrated publication still requires
coordinator clean allcheck including physical RPi5 validation.
