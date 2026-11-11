------------------------- MODULE ConsoleRoom -------------------------
\* One checked console-guard holder across a complete DDB stop and a possible refusal.
\* A second legacy raw writer shows why the exit room fence needs serialization.
\* Two slots represent a FIFO with one remaining free slot, not its device size.
EXTENDS Naturals
CONSTANTS
    \* @type: Bool;
    SERIAL,
    \* @type: Bool;
    FENCE,
    \* @type: Bool;
    REFUSAL_GUARD
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
    bad,
    \* @type: Bool;
    refused
vars == <<fifo, holder, normal, raw, phase, bad, refused>>
\* Snapshot immediately after the guarded FIFO-room check. The raw writer
\* may already have completed its earlier column bookkeeping. It has no
\* physical-room observation yet. This is one feasible mid-section state.
Init == /\ fifo = 1 /\ holder = "normal" /\ normal = "checked"
        /\ raw = "ready" /\ phase = "running" /\ bad = FALSE
        /\ refused = FALSE
RawCheck == /\ phase \in {"running", "released"} /\ raw = "ready" /\ fifo < 2
            /\ (~SERIAL \/ holder = "free")
            /\ holder' = IF SERIAL THEN "raw" ELSE holder
            /\ raw' = "checked" /\ UNCHANGED <<fifo, normal, phase, bad, refused>>
NormalStore == /\ (phase = "released" \/ (phase = "running" /\ refused))
               /\ normal = "checked"
               /\ bad' = (bad \/ fifo = 2)
               /\ fifo' = IF fifo < 2 THEN fifo + 1 ELSE fifo
               /\ normal' = "done" /\ holder' = "free"
               /\ UNCHANGED <<raw, phase, refused>>
RawStore == /\ (phase = "released" \/ (phase = "running" /\ refused))
            /\ raw = "checked"
            /\ bad' = (bad \/ fifo = 2)
            /\ fifo' = IF fifo < 2 THEN fifo + 1 ELSE fifo
            /\ raw' = "done" /\ holder' = IF SERIAL THEN "free" ELSE holder
            /\ UNCHANGED <<normal, phase, refused>>
Stop == /\ phase = "running" /\ normal = "checked"
        /\ phase' = "stopped" /\ UNCHANGED <<fifo, holder, normal, raw, bad, refused>>
LastDebugByte == /\ phase = "stopped" /\ fifo < 2
                 /\ fifo' = fifo + 1 /\ phase' = "last-byte"
                 /\ UNCHANGED <<holder, normal, raw, bad, refused>>
Release == /\ phase = "last-byte" /\ (~FENCE \/ fifo < 2)
           /\ phase' = "released" /\ UNCHANGED <<fifo, holder, normal, raw, bad, refused>>
\* Refusal provides no stop authority. A held lock sends the report to the
\* ring. On success, collapse the polled last byte and unlock: the guard
\* excludes new ordinary checks throughout the real output.
RefusalRetain == /\ phase \in {"running", "released"} /\ ~refused
                 /\ REFUSAL_GUARD /\ holder # "free"
                 /\ refused' = TRUE
                 /\ UNCHANGED <<fifo, holder, normal, raw, phase, bad>>
RefusalWrite == /\ phase \in {"running", "released"} /\ ~refused /\ fifo < 2
                /\ (~REFUSAL_GUARD \/ holder = "free")
                /\ fifo' = fifo + 1 /\ refused' = TRUE
                /\ UNCHANGED <<holder, normal, raw, phase, bad>>
DeviceDrain == /\ fifo > 0 /\ fifo' = fifo - 1
               /\ UNCHANGED <<holder, normal, raw, phase, bad, refused>>
Done == /\ normal = "done" /\ raw = "done" /\ UNCHANGED vars
Next == RawCheck \/ NormalStore \/ RawStore \/ Stop \/
        LastDebugByte \/ Release \/ RefusalRetain \/ RefusalWrite \/
        DeviceDrain \/ Done
Spec == Init /\ [][Next]_vars
TypeOK == fifo \in 0..2 /\ holder \in {"free", "normal", "raw"} /\
          normal \in {"checked", "done"} /\ raw \in {"ready", "checked", "done"} /\
          phase \in {"running", "stopped", "last-byte", "released"}
NoFullStore == ~bad
Safety == TypeOK /\ NoFullStore

CInitFixed == SERIAL = TRUE /\ FENCE = TRUE /\ REFUSAL_GUARD = TRUE
CInitNoFence == SERIAL = TRUE /\ FENCE = FALSE /\ REFUSAL_GUARD = TRUE
CInitNoSerial == SERIAL = FALSE /\ FENCE = TRUE /\ REFUSAL_GUARD = TRUE
CInitOld == SERIAL = FALSE /\ FENCE = FALSE /\ REFUSAL_GUARD = FALSE
CInitNoRefusalGuard == SERIAL = TRUE /\ FENCE = TRUE /\ REFUSAL_GUARD = FALSE
=====================================================================
