# GitHub issue #713: force each fixture probe's payload-free Forced case at
# its first machine instruction, in the second ("forced") round only. The
# round's keys arrive in x0, in the high half: 0x50 direct, 0x51 eight
# leaves, 0x52 nine, 0x53 the shared-payload variant, 0x54 the same variant forced to a case
# with a payload (#897), 0x55 an array-holding variant returned through x8 (#962).
# Only takibi-force-variant-return, reading the compiler sidecar, decides
# where the result goes; the caller's UART line says what it observed.
set confirm off
set pagination off
break *debug_abi_direct if $x0 == 0x5000000000
break *debug_abi_eight if $x0 == 0x5100000000
break *debug_abi_nine if $x0 == 0x5200000000
break *debug_abi_shared if $x0 == 0x5300000000
break *debug_abi_payload if $x0 == 0x5400000000
break *debug_abi_array if $x0 == 0x5500000000
python
import gdb
for name in ("DebugAbiDirect", "DebugAbiEightLeaves", "DebugAbiNineLeaves",
             "DebugAbiShared"):
    gdb.execute("continue")
    gdb.execute(f"takibi-force-variant-return {name} Forced")
gdb.execute("continue")
gdb.execute("takibi-force-variant-return DebugAbiShared Wide 0x5A5A0077")
gdb.execute("continue")
gdb.execute("takibi-force-variant-return DebugAbiArray Forced")
gdb.write("debug-return-abi-gdb: all six forced\n")
end
delete
# Detaching resumes the guest, which prints its verdicts and exits.
