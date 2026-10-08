# GitHub issue #713: force each fixture probe's payload-free Forced case at
# its first machine instruction, in the second ("forced") round only. The
# round's keys arrive in x0, in the high half: 0x50 direct, 0x51 eight
# leaves, 0x52 nine.
# Only takibi-force-variant-return, reading the compiler sidecar, decides
# where the result goes; the caller's UART line says what it observed.
set confirm off
set pagination off
break *debug_abi_direct if $x0 == 0x5000000000
break *debug_abi_eight if $x0 == 0x5100000000
break *debug_abi_nine if $x0 == 0x5200000000
python
import gdb
for name in ("DebugAbiDirect", "DebugAbiEightLeaves", "DebugAbiNineLeaves"):
    gdb.execute("continue")
    gdb.execute(f"takibi-force-variant-return {name} Forced")
gdb.write("debug-return-abi-gdb: all three forced\n")
end
delete
# Detaching resumes the guest, which prints its verdicts and exits.
