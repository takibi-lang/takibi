# Typed exception CPU storage: measured space

The linked-image measurement compares published `e15c4f54` with production
source `95512e7b`. The archived baseline is
`/workspaces/takibi-claude/.git/takibi-land/baselines/kernel-green-e15c4f54`;
its manifest hashes were checked before measuring. `EXCEPTION_CPU_SPACE.json`
records both production ELFs, all four production/debug objects, hashes,
objdump commands and single-frame observations. Candidate copies and raw
assembly are retained at the artifact root recorded there.

## Fixed storage and reservation

| Boundary (bytes) | QEMU base | QEMU candidate | RPi5 base | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| Linked text | 815420 | 817488 | 4200424 | 4202604 |
| Linked data | 4616 | 4632 | 5592 | 5608 |
| Linked BSS span | 1302528 | 1318912 | 1925120 | 1937408 |
| `usable_ram_start` | 0x40208000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The working capture is 2064 bytes and the flat publication is 2072 bytes.
Each CPU retains a capture and an observed publication scratch, while the
published array retains a third record. Four CPUs therefore change the
original 8288-byte snapshot array to a 16544-byte typed capture/scratch
array plus an 8288-byte publication array: **16544 extra payload bytes**.
The stopped-root payload changes from 160 to 128 bytes, with its 32 bytes of
atomic sequence metadata moved to a separate array; that move has no net
payload cost. Capture flags remain four bytes. No pool object, heap page or
per-process allocation is introduced.

BSS spans include alignment, so they increase by 16384 bytes on QEMU and
12288 bytes on RPi5 rather than exactly the payload delta. The whole QEMU
image reservation increases by 32768 bytes (eight 4096-byte pages); RPi5's
image reservation stays unchanged within its existing alignment boundary.
That unchanged reservation does not make the additional payload free.
These are image/reservation observations, not peak runtime allocator occupancy.
The maintained boot, stopped DDB and terminal crash workloads supply the
separate functional boundary. Kernelbuild, the 13 real-API compiler controls,
normal/oops/DDB/GDB QEMU chain, model checks and RPi5 lane each exited zero
on source `95512e7b`. The runtime manifest and capture hashes are recorded
in the JSON. The UART and software DDB views, concurrent fault report and
RPi5 guarded fault recovery retain their expected contracts; terminal captures retain this fixed storage
until reboot and have no ordinary teardown.

## Why the copies remain separate

The working capture retains the faulting CPU's cached diagnostic state even
when reporting other CPUs. Reusing it as reader scratch would destroy that
state. The flat builtin publication is the coherent peer/debugger boundary;
its compiler-controlled array fields are copied through `publish_copy` and
are not borrowed as ordinary slices. Reader scratch remains per CPU so a
reporter that continues after bounded report-lock abandonment cannot share
mutable scratch with another reporter. An explicit local record instead
would add a 2072-byte temporary on an exception path. No broader ownership
or memory framework is introduced to merge these lifetimes.

## Stack observation boundary

The corrected measurement accepts decimal and hexadecimal pre-indexed STP
prologues. The production build gate's hexadecimal-STP undercount is a
separate host defect (#1485); no shared frame budget is changed here.
Both archived baseline and candidate measure scheduler-probe frames of
3184 bytes in production and 3312 bytes in debug, and ext2-update frames of
2528/2640 bytes. The gate's reported scheduler value of 3216 is not its
physical debug frame size.

Candidate copy-helper frames are 16 bytes in production and 32 in debug on
both platforms: no full-record stack temporary appears. Publication follows
capture -> stop report -> publish -> render -> core render -> record render
-> trace render at the source-call level. Ordered rendering is a separate,
later path through crash_console_dispatch_cached after publication returns
to the terminal console loop. It is not an intervening publication frame.
The JSON records individual prologue frames for both branches, not a sum
that combines them. Source calls may also become tail calls in optimized
objects; no source-level chain is asserted to imply simultaneously retained
physical frames. Formatter callees, exception entry and other callers are
not bounded by this measurement. Neither a passing single-frame gate nor
these selected observations proves a 16 KiB whole-callpath stack bound.

The safety cost is retained explicitly. The next measurement trigger is a
changed crash-record schema, reader/capture lifetime, publisher representation,
exception callpath, or completion of the next kernel feature that changes the
image or allocation workload. Cross-OS allocator comparisons retain their
existing scope; this static exception-storage change needs no new OS workload.
