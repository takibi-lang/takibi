------------------------- MODULE ConsoleRoom -------------------------
\* One checked console-guard holder across one complete, returning DDB stop.
\* A second legacy raw writer shows why the exit room fence needs serialization.
\* Two slots represent a FIFO with one remaining free slot, not its device size.
EXTENDS Naturals
CONSTANTS
    \* @type: Bool;
    SERIAL,
    \* @type: Bool;
    FENCE
VARIABLES
    \* @type: Int;
    fifo,
    \* @type: Str;
    holder,
    \* @type: Str;
    normal,
    \* @type: Str;
    raw,
    \* @type: Str;
    phase,
    \* @type: Bool;
    bad
vars == <<fifo, holder, normal, raw, phase, bad>>
\* Snapshot immediately after the guarded FIFO-room check. The raw writer
\* may already have completed its earlier column bookkeeping. It has no
\* physical-room observation yet. This is one feasible mid-section state.
Init == /\ fifo = 1 /\ holder = "normal" /\ normal = "checked"
        /\ raw = "ready" /\ phase = "running" /\ bad = FALSE
RawCheck == /\ phase \in {"running", "released"} /\ raw = "ready" /\ fifo < 2
            /\ (~SERIAL \/ holder = "free")
            /\ holder' = IF SERIAL THEN "raw" ELSE holder
            /\ raw' = "checked" /\ UNCHANGED <<fifo, normal, phase, bad>>
NormalStore == /\ phase = "released" /\ normal = "checked"
               /\ bad' = (bad \/ fifo = 2)
               /\ fifo' = IF fifo < 2 THEN fifo + 1 ELSE fifo
               /\ normal' = "done" /\ holder' = "free"
               /\ UNCHANGED <<raw, phase>>
RawStore == /\ phase = "released" /\ raw = "checked"
            /\ bad' = (bad \/ fifo = 2)
            /\ fifo' = IF fifo < 2 THEN fifo + 1 ELSE fifo
            /\ raw' = "done" /\ holder' = IF SERIAL THEN "free" ELSE holder
            /\ UNCHANGED <<normal, phase>>
Stop == /\ phase = "running" /\ normal = "checked"
        /\ phase' = "stopped" /\ UNCHANGED <<fifo, holder, normal, raw, bad>>
LastDebugByte == /\ phase = "stopped" /\ fifo < 2
                 /\ fifo' = fifo + 1 /\ phase' = "last-byte"
                 /\ UNCHANGED <<holder, normal, raw, bad>>
Release == /\ phase = "last-byte" /\ (~FENCE \/ fifo < 2)
           /\ phase' = "released" /\ UNCHANGED <<fifo, holder, normal, raw, bad>>
DeviceDrain == /\ fifo > 0 /\ fifo' = fifo - 1
               /\ UNCHANGED <<holder, normal, raw, phase, bad>>
Done == /\ normal = "done" /\ raw = "done" /\ UNCHANGED vars
Next == RawCheck \/ NormalStore \/ RawStore \/ Stop \/
        LastDebugByte \/ Release \/ DeviceDrain \/ Done
Spec == Init /\ [][Next]_vars
TypeOK == fifo \in 0..2 /\ holder \in {"free", "normal", "raw"} /\
          normal \in {"checked", "done"} /\ raw \in {"ready", "checked", "done"} /\
          phase \in {"running", "stopped", "last-byte", "released"}
NoFullStore == ~bad
Safety == TypeOK /\ NoFullStore

CInitFixed == SERIAL = TRUE /\ FENCE = TRUE
CInitNoFence == SERIAL = TRUE /\ FENCE = FALSE
CInitNoSerial == SERIAL = FALSE /\ FENCE = TRUE
CInitOld == SERIAL = FALSE /\ FENCE = FALSE
=====================================================================
