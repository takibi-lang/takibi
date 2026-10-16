------------------------- MODULE PacketReserveScan -------------------------
(***************************************************************************)
(* PacketReserve.tla with the reserve check's scan made concurrent (#740). *)
(* The capability holder decides a keeping transmit by walking the pool    *)
(* slots one at a time (net_tx_keep_slot: virtio_pkt_out_count /           *)
(* gem_pkt_out_count, each slot under its own lock) and counting the ones  *)
(* the stack has: empty (a turn's packet, a claimed kept one) or parked    *)
(* Kept. Meanwhile another core may claim a Kept packet or free a claimed  *)
(* one, under that slot's lock only.                                       *)
(*                                                                         *)
(* Per-slot states: "Posted" (an RX descriptor holds it), "Free", "Held"   *)
(* (the turn's packet, slot empty), "Kept" (parked), "Claimed" (taken out  *)
(* off-turn, slot empty), "Tx", "TxKept" (a transmit whose completion      *)
(* parks it Kept). Checked:                                                *)
(*   RingNeverDrains -- at least one slot is Posted;                        *)
(*   ScanNeverLow    -- when the holder decides, its count is at least the  *)
(*                      true number of buffers the stack has;              *)
(*   TxNeverStarves  -- between turns, with the ring full, a Free buffer   *)
(*                      is left for a kernel-built frame.                  *)
(*                                                                         *)
(* FAULT 0 is the driver. FAULT 1 is a scan that does not count an empty   *)
(* slot (it treats claimed packets as in the pool): it undercounts and     *)
(* keeps past the reserve.                                                 *)
(***************************************************************************)

EXTENDS Integers, FiniteSets

CONSTANTS
    \* @type: Int;
    N,
    \* @type: Int;
    D,
    \* @type: Int;
    RESERVE,
    \* @type: Int;
    FAULT

VARIABLES
    \* @type: Int -> Str;
    st,
    \* @type: Str;
    hphase,      \* "Idle", "Turn" (holds a packet), "Scan", "Decide", "Tx"
    \* @type: Int;
    idx,         \* next slot the scan reads
    \* @type: Int;
    cnt          \* what the scan has counted so far

\* @type: <<Int -> Str, Str, Int, Int>>;
vars == <<st, hphase, idx, cnt>>

Slots == 0..(N - 1)

Count(s) == Cardinality({i \in Slots : st[i] = s})

\* The buffers the stack has, by the slots' true states.
OutCount == Cardinality({i \in Slots : st[i] \in {"Held", "Kept", "Claimed"}})

FreeSlots == {i \in Slots : st[i] = "Free"}

Init ==
    /\ st = [i \in Slots |-> IF i < D THEN "Posted" ELSE "Free"]
    /\ hphase = "Idle"
    /\ idx = 0
    /\ cnt = 0

(* The holder's refill, one descriptor per holder step: a Free slot to *)
(* Posted while fewer than D are posted. The driver refills every empty *)
(* descriptor at once; one per step is weaker for RingNeverDrains, so a *)
(* pass here holds for it too, and keeps the model free of set          *)
(* enumeration for Apalache.                                             *)
\* @type: (Int -> Str) => Set(Int -> Str);
Refilled(s) ==
    IF \E f \in Slots : s[f] = "Free"
       /\ Cardinality({i \in Slots : s[i] = "Posted"}) < D
    THEN { [s EXCEPT ![f] = "Posted"] : f \in {g \in Slots : s[g] = "Free"} }
    ELSE { s }

(* net_rx_acquire: a posted buffer becomes the turn's packet; refill. *)
Acquire ==
    /\ hphase = "Idle"
    /\ \E p \in Slots :
        /\ st[p] = "Posted"
        /\ st' \in Refilled([st EXCEPT ![p] = "Held"])
    /\ hphase' = "Turn"
    /\ UNCHANGED <<idx, cnt>>

(* acquire's no-frame path: refill only. *)
Poll ==
    /\ hphase = "Idle"
    /\ st' \in Refilled(st)
    /\ UNCHANGED <<hphase, idx, cnt>>

HeldSlot == CHOOSE i \in Slots : st[i] = "Held"

(* net_rx_release: the packet back Free, refill. *)
Release ==
    /\ hphase = "Turn"
    /\ st' \in Refilled([st EXCEPT ![HeldSlot] = "Free"])
    /\ hphase' = "Idle"
    /\ UNCHANGED <<idx, cnt>>

(* net_rx_send_reply: the packet goes out as TX. *)
Reply ==
    /\ hphase = "Turn"
    /\ st' = [st EXCEPT ![HeldSlot] = "Tx"]
    /\ hphase' = "Tx"
    /\ UNCHANGED <<idx, cnt>>

(* net_transmit_ready: a kernel-built frame in a Free buffer. *)
SendBuilt ==
    /\ hphase = "Idle"
    /\ \E f \in Slots :
        /\ st[f] = "Free"
        /\ st' = [st EXCEPT ![f] = "Tx"]
    /\ hphase' = "Tx"
    /\ UNCHANGED <<idx, cnt>>

(* The completion, then the refill: a kept transmit parks Kept. *)
TxComplete ==
    /\ hphase = "Tx"
    /\ \E t \in Slots :
        \/ /\ st[t] = "Tx"
           /\ st' \in Refilled([st EXCEPT ![t] = "Free"])
        \/ /\ st[t] = "TxKept"
           /\ st' \in Refilled([st EXCEPT ![t] = "Kept"])
    /\ hphase' = "Idle"
    /\ UNCHANGED <<idx, cnt>>

(* net_packet_kept_claim then net_packet_kept_resend, by the holder: in *)
(* place, Kept again at completion.                                      *)
Resend ==
    /\ hphase = "Idle"
    /\ \E k \in Slots :
        /\ st[k] = "Kept"
        /\ st' = [st EXCEPT ![k] = "TxKept"]
    /\ hphase' = "Tx"
    /\ UNCHANGED <<idx, cnt>>

(* net_tx_keep_slot begins its scan, between turns. *)
ScanStart ==
    /\ hphase = "Idle"
    /\ hphase' = "Scan"
    /\ idx' = 0
    /\ cnt' = 0
    /\ UNCHANGED st

(* One slot, read under its lock. *)
ScanStep ==
    /\ hphase = "Scan"
    /\ idx < N
    /\ LET counted ==
             IF FAULT = 1 THEN {"Kept"} ELSE {"Held", "Kept", "Claimed"}
       IN cnt' = cnt + (IF st[idx] \in counted THEN 1 ELSE 0)
    /\ idx' = idx + 1
    /\ hphase' = IF idx + 1 = N THEN "Decide" ELSE "Scan"
    /\ UNCHANGED st

(* net_transmit_keep on the scanned count: a Free buffer sent and kept,  *)
(* or, past the reserve, sent plainly. No Free buffer: nothing is sent.  *)
KeepDecide ==
    /\ hphase = "Decide"
    /\ IF FreeSlots = {}
       THEN /\ st' = st
            /\ hphase' = "Idle"
       ELSE /\ \E f \in FreeSlots :
                st' = [st EXCEPT ![f] =
                         IF cnt + 1 <= N - RESERVE THEN "TxKept" ELSE "Tx"]
            /\ hphase' = "Tx"
    /\ UNCHANGED <<idx, cnt>>

(* Off-turn, any core, the slot's lock only: net_packet_kept_claim takes *)
(* a Kept packet out; net_packet_free returns a claimed one Free. Both   *)
(* may interleave with every holder step, the scan included.             *)
Claim ==
    /\ \E k \in Slots :
        /\ st[k] = "Kept"
        /\ st' = [st EXCEPT ![k] = "Claimed"]
    /\ UNCHANGED <<hphase, idx, cnt>>

FreeKept ==
    /\ \E k \in Slots :
        /\ st[k] = "Claimed"
        /\ st' = [st EXCEPT ![k] = "Free"]
    /\ UNCHANGED <<hphase, idx, cnt>>

Next ==
    \/ Acquire \/ Poll \/ Release \/ Reply \/ SendBuilt \/ TxComplete
    \/ Resend \/ ScanStart \/ ScanStep \/ KeepDecide \/ Claim \/ FreeKept

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ \A i \in Slots :
        st[i] \in {"Posted", "Free", "Held", "Kept", "Claimed", "Tx", "TxKept"}
    /\ hphase \in {"Idle", "Turn", "Scan", "Decide", "Tx"}
    /\ idx \in 0..N /\ cnt \in 0..N

RingNeverDrains == Count("Posted") >= 1

(* A concurrent free only lowers the true count after the scan read it: *)
(* the scanned count may be high, never low.                            *)
ScanNeverLow == hphase = "Decide" => cnt >= OutCount

(* The model refills one descriptor per step, so the spare is checked  *)
(* once the ring is full.                                               *)
TxNeverStarves ==
    (hphase = "Idle" /\ Count("Posted") = D) => FreeSlots # {}

Safety ==
    /\ TypeOK
    /\ RingNeverDrains
    /\ ScanNeverLow
    /\ TxNeverStarves

CInitFixed == N = 5 /\ D = 3 /\ RESERVE = 4 /\ FAULT = 0
CInitGem == N = 4 /\ D = 1 /\ RESERVE = 2 /\ FAULT = 0
CInitSkipEmpty == N = 2 /\ D = 1 /\ RESERVE = 1 /\ FAULT = 1
=============================================================================
