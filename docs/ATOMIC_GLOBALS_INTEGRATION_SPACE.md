# Atomic global integration measurement, 2026-11-09

This measures the combined online-prefix and virtio-net used-address
AtomicWord migrations against the verified published 34ee3015 production
artifacts. The component reports retain their original source scopes; their
deltas are not summed in place of rebuilding this combination. Both actual
production kernels were rebuilt here. Original and candidate ELF hashes were
checked before and after read-only inspection.

| Linked boundary (bytes) | QEMU before | QEMU combined | RPi5 before | RPi5 combined |
| --- | ---: | ---: | ---: | ---: |
| text | 822792 | 822792 | 4207396 | 4207396 |
| data | 4624 | 4624 | 5600 | 5600 |
| bss | 1318912 | 1318912 | 1933312 | 1933312 |
| usable_ram_start address | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

All data/BSS symbol sizes and all allocated section layouts are identical.
There is no change to pool capacity, allocator metadata, retained pages or
allocation lifetime, and no physical page is freed. Existing occupancy
evidence remains applicable at that unchanged workload boundary.

QEMU has 23 changed instruction words, confined to the three counter
functions and the two net metadata functions. The counter functions remain
84, 52 and 40 bytes. Net setup grows from 168 to 172 bytes and consumes four
bytes of existing alignment padding; its register allocation and FDE range
also change. The stopped DDB reader remains 104 bytes. Only .text and the
setup range in .eh_frame differ among allocated sections. RPi5 has exactly
four changed instruction words in the counter functions and only .text
differs. Its GEM driver does not compile the virtio-net address global.

Instruction encodings, function sizes and section bytes are measured here;
this is not a cycle-latency or physical-coherence measurement. The net
readiness and Unknown handling, MachineStopped borrow, raw ring access,
DMA ownership and guarded queue setup API are unchanged. The conservative
CPU prefix, fallback one, boot single-writer premise and independent
world-stop participant mask are unchanged. Caller confinement and source
premises remain bounded build checks, not CPU-identity or device proofs.

The combined ledger removes two untyped allowance rows (36 to 34) using
existing typed atomic cells. It separately records the counter source-policy
premise (trust_build_checks 22 to 23); that trust is not erased by replaying
the address-only component. Component implementation sources, their typed
boundaries and both sets of caller rows are preserved.

The JSON companion records the combined source fingerprint, exact linked
ELF and object hashes, compiler facts hashes, every changed instruction word
and before/after boundaries. This record is bound to the production source
tree, independently of documentation-only integration commits.

Assessment: adopt both existing-type migrations at unchanged linked space
and payload. Keep the additional cold setup instruction and acquire/release
cost explicit without claiming measured time. No language, model action,
ownership API or allocator redesign is added. Measure again after a changed
resource/lifetime or allocation workload, or completion of the next kernel
feature/stage.

## DMA fixture correction

The separate DMA fixture consumer now calls `atomic_word_load` before its
existing integer-to-pointer cast. The maintained DMA QEMU lane passed with
this correction. Both production ELF/object hashes and all six recorded
compiler-fact hashes were verified identical to the measurements above.
The fixture is included in the publication source fingerprint, so the
checkpoint is rebound to the corrected source without changing the measured
two-migration milestone or claiming a new production layout measurement.
