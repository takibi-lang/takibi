# Profile timeline storage review

Normal linked QEMU and RPi5 kernels compared with 4586b164f. The existing
busy-pair profile uses the same 512 event slots per CPU.

| Boundary | QEMU baseline to candidate | RPi5 baseline to candidate |
| --- | --- | --- |
| Text | 831892 to 832084 B | 4225504 to 4225664 B |
| Data | 4624 B unchanged | 5600 B unchanged |
| BSS | 1310720 B unchanged | 1912832 B unchanged |
| Timeline BSS symbol | 98400 B unchanged | 98400 B unchanged |
| usable_ram_start | 0x40210000 unchanged | 0x7e0000 unchanged |

No linked data or BSS symbol changed size. The kernel memory-map check
confirms both usable RAM boundaries and five allocator expectations. Both
kernel builds classify the timeline array as a per-CPU store.

The active writer takes the existing counted CPU authority inside the IRQ
mask. In both normal objects its static frame changes from 80 to 64 bytes
and its additional called writer uses 80 bytes. The pair needs 64 more
bytes before downstream calls. The report frame remains 112 bytes.
These measurements cover static frames and linked space. They provide no
elapsed writer time or whole-stack bound.

Remeasure the linked image and writer frames when the timeline storage,
event format or active CPU-authority path changes.
