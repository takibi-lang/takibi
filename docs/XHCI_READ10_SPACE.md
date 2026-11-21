# xHCI READ(10) receipt space

A successful fixed-size READ(10) retains the data DMA CPU token until the
matching command status wrapper (CSW) is checked. The receipt holds the
matching final one-TRB Transfer Event and the submitted length. The driver
checks the received extent, 13-byte CSW length, signature, tag, passing
status, and zero residue before copying. A short completed data phase
still collects the CSW. The code preserves the existing recovery outcomes
for missing events, failed halt/reset, and completed data-phase errors.
The postcondition for the copy concerns the actual destination. It relies
on the controller and device honoring their completion records, and on
the existing cache and event-correlation assumptions.

The RPi5 receive buffer now occupies 0x640000 through 0x64ffff, the first
64 KiB of the existing 256 KiB DMA aperture. The fixed PCI offset preserves
64 KiB alignment. Linked symbol checks bind this placement and the complete
span to the one-TRB submission. Controller placement, ring ownership and
the BOT receipt remain distinct premises.

| Boundary | Published baseline | Candidate |
| --- | ---: | ---: |
| Normal QEMU linked text (bytes) | 834484 | 834484 |
| Normal RPi5 linked text (bytes) | 4227680 | 4228864 |
| Normal RPi5 linked data (bytes) | 5600 | 5600 |
| Normal RPi5 linked BSS (bytes) | 1908736 | 1908736 |
| RPi5 usable RAM start | 0x7e0000 | 0x7e0000 |

The baseline is the published getrusage fixture with a later documentation
update. The normal RPi5 main object reports unchanged 48, 64 and 80 byte
frames for data receive, CSW receive and disk read respectively. The new
READ(10) worker and checked copy each report a 64-byte frame. Individual
frames do not measure peak call-chain occupancy. The existing aperture
size, DMA pool capacity, and writable image totals are unchanged.
These are board-free build measurements.

Protocol sources: [Intel xHCI 1.2b, section 4.10.1.1.2](https://cdrdv2-public.intel.com/625472/625472_xHCI_Rev1_2b.pdf),
[Intel Normal TRB layout, section 6.4.1](https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/extensible-host-controler-interface-usb-xhci.pdf),
and [USB-IF BOT 1.0, sections 6.3 and 6.7.2](https://www.usb.org/sites/default/files/usbmassbulk_10.pdf).
