# #720: exact xHCI request/event matching, space (2026-10-16)

usb_await_event now accepts only an event whose TRB Pointer lies in the
request's TRBs and, for a transfer, whose slot and endpoint match
(kernel/drivers/usb/xhci_event_match.tkb). Measured with
scripts/space_delta.py against main 292bc665 (same numbers as against 7c9cfba6):

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 697312 | 697312 | 747232 | 747912 |
| data | 4760 | 4760 | 2889552 | 2889560 |
| bss | 1486352 | 1486352 | 1692672 | 1692672 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |
rpi5: xhci_await_type 4 -> gone, xhci_await_want 32 (new),
xhci_foreign_events 8 (new)
```

Assessment:
- RPi5 text +680 B: the matcher, the per-run expected-address setup in
  xhci_ring_run, and the foreign-event counter. Accepted: it is the runtime
  check that the completes witness needed.
- Data +8 B net (the expected-request record replaces the type word).
- usable_ram_start unchanged; QEMU does not link the xHCI driver.
- Runtime: one comparison chain per consumed event; no extra cache work.
