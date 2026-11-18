# Boot execution context space review

Normal linked QEMU and RPi5 kernels compared with ddf96089. Both use the
same boot workloads and permanent rootfs metadata storage.

| Boundary | QEMU baseline to candidate | RPi5 baseline to candidate |
| --- | --- | --- |
| Text | 827848 to 827800 B | 4221044 to 4220980 B |
| Data | 4608 to 4600 B | 5584 to 5576 B |
| Linked BSS | 1310720 B unchanged | 1916928 to 1912832 B |
| boot_execution symbol | 184 B removed | 184 B removed |
| rootfs_metadata symbol | 1024 B unchanged | 1024 B unchanged |
| usable_ram_start | 0x40210000 unchanged | 0x7e0000 unchanged |
| kernel_test_driver_run normal static frame | 1120 to 1376 B | 1120 to 1376 B |

Boot exec shares the published syscall mount descriptor. Keeping the image
plan in its only reader, the boot driver, removes the global and adds 256
bytes to that function's normal frame, below the 2048-byte function ceiling.
The linked BSS change includes alignment and is distinct from the removed
184-byte symbol. The allocator start and reserved image span stay fixed.
The plan still refers to the same permanent window; there is no change to
its allocation workload. The stack sizes describe individual functions.
