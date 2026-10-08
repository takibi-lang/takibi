# Raw-authority audit correction space review (2026-10-08)

This incremental review covers compiler reference-mint confinement and shared
place checks, production ELF alignment validation, replay failure diagnostics
and documentation corrections. It is not completion of the raw-authority
stage or a new kernel feature. The corrections add no persistent field,
owner slot, pool payload, storage or allocation policy. They add no unsafe
assertion or raw mint. The native fixtures are separate host executables.

Fresh standard production QEMU/RPi5 linked kernels were compared with
00cd6dd0 (including the per-signal action table) using
`scripts/space_delta.py`, llvm-size-19 and llvm-nm-19:

| Boundary | QEMU base | QEMU correction | RPi5 base | RPi5 correction |
| --- | ---: | ---: | ---: | ---: |
| text bytes | 719052 | 719068 | 728740 | 728740 |
| data bytes | 5070 | 5070 | 2888776 | 2888776 |
| BSS bytes | 1658592 | 1658592 | 1697600 | 1697600 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
| image reservation bytes | 2392064 | 2392064 | 5341184 | 5341184 |

No data/BSS symbol changed size. QEMU text grows 16 bytes; RPi5 text is
unchanged. Adopt the local validation and compiler corrections. No measured
storage cost justifies a representation change or weakening safety.

The allocation-workload evidence is reused at its existing strength because
these corrections do not change allocation behavior. The upstream signal
change has already changed ProcessRecord from 872 to 1832 bytes; its linked
cost and computed four-record process-chunk capacity are recorded in
`SIGNAL_ACTIONS_SPACE_2026-10-08.md`. The older endpoint TSVs still describe
their earlier 872-byte record workload. They are not new 1832-byte record
measurements, current peak occupancy or coherent global snapshots. No fresh
pool/OS comparison or whole-stack high-water measurement is claimed here.
Final clean allcheck supplies the separate real RPi5 functional evidence.

ELF SHA-256 at the measured correction:

- QEMU: 08dc7b00d5d9d392268327d49991ae2281331e9c9a7dd5036161e4f0bee027b5
- RPi5: c99304925c2a343806cf5c1c55e5ca210647574d9cdd8c5983fc0fb94415de59

Next measurement: the typed atomic/probe or bounded-copy milestone, process
trust-boundary separation, final raw-authority confinement, or a changed
allocation/lifetime workload. Those stage/feature completions must receive
representative fresh workload measurement rather than incremental reuse.
