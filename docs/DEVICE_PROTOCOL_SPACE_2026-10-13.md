# #720 option a, slice 1 (device protocols): space measurement (2026-10-13)

The compiler slice of GitHub issue #720 option a -- a `tx`/`rx` direction on
a protocol's retained region, generated cache work on publishing and
finishing edges, device-state spans, `--device-semantics-file` with
`kernel/DEVICE_SEMANTICS_FILES` -- against main e8f52b1b, measured with
scripts/space_delta.py. No maintained kernel declares a device protocol yet
(the list is empty), and the build only gains the empty flag list, so the
linked images are expected to be identical; this records that they are.

```
base main -> working tree
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 712488 | 712488 | 725792 | 725792 |
| data | 5392 | 5392 | 2889256 | 2889256 |
| bss | 1660704 | 1660704 | 1700976 | 1700976 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
no data/BSS symbol changed size
```

The only consumer is linux_user/protocol_tx, a native test outside the
kernel accounting boundary. A device protocol adds no storage: its state
owners are the same one-region owners as any protocol, the span is the
existing two-word DmaDeviceSpan built on the stack, and the cache work is
code. The next measurement is due with slice 2, when the xHCI producer
rings move onto device protocols and their backing globals become
`region let mut [Trb; N] align(64)`.
