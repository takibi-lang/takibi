--------------------------- MODULE PacketReserve ---------------------------
(***************************************************************************)
(* Kept packets never starve the RX ring or a kernel-built transmit (#740, *)
(* the RX capability split and the TCP retransmit queue). A transmitted   *)
(* TCP segment may be kept in its pool buffer for retransmission           *)
(* (net_transmit_keep); it is resent in place and comes back kept         *)
(* (net_packet_kept_resend), and its free only returns the buffer to the  *)
(* pool (net_packet_free). Only the RX capability's holder refills the    *)
(* ring, and it fills every empty descriptor first. If kept packets took  *)
(* too many buffers, either the ring would empty (no frame arrives, no    *)
(* acquire runs, nothing refills it) or every buffer the refill leaves    *)
(* would be posted and net_transmit_ready would find none.                 *)
(*                                                                         *)
(* Counts only: N pool buffers, D RX descriptors. A buffer is posted (an  *)
(* RX descriptor holds it), free, held (the one packet of the current RX  *)
(* turn), kept, or in TX (completed within the turn that sent it; txkeep  *)
(* says whether its completion parks it kept). Keeping is refused when it *)
(* would leave fewer than RESERVE buffers outside the kept set; the        *)
(* caller then sends the frame plainly and keeps a copy.                   *)
(*                                                                         *)
(* RESERVE D + 1 is the driver's (VIRTIO_PKT_RESERVE 9 for 10/8,           *)
(* GEM_PKT_RESERVE 2 for 4/1). Controls: RESERVE D starves the transmit   *)
(* (a 4-buffer pool, 2 descriptors); RESERVE 0 on GEM's shape drains the  *)
(* ring.                                                                   *)
(***************************************************************************)

EXTENDS Integers

CONSTANTS
    \* @type: Int;
    N,
    \* @type: Int;
    D,
    \* @type: Int;
    RESERVE

VARIABLES
    \* @type: Int;
    posted,
    \* @type: Int;
    free,
    \* @type: Int;
    held,
    \* @type: Int;
    kept,
    \* @type: Int;
    tx,
    \* @type: Int;
    txkeep

\* @type: <<Int, Int, Int, Int, Int, Int>>;
vars == <<posted, free, held, kept, tx, txkeep>>

Min(a, b) == IF a < b THEN a ELSE b

Init ==
    /\ posted = D
    /\ free = N - D
    /\ held = 0
    /\ kept = 0
    /\ tx = 0
    /\ txkeep = 0

(* The capability's holder refills every empty descriptor it can. *)
Refill(p, f) ==
    /\ posted' = Min(D, p + f)
    /\ free' = f - (posted' - p)

(* net_rx_acquire: a used entry's buffer comes back Filled, and the ring *)
(* is refilled in the same call.                                          *)
Acquire ==
    /\ held = 0 /\ tx = 0
    /\ posted > 0
    /\ Refill(posted - 1, free)
    /\ held' = 1
    /\ UNCHANGED <<kept, tx, txkeep>>

(* net_rx_acquire's None path: no frame, but the holder still refills    *)
(* what off-turn frees returned.                                          *)
Poll ==
    /\ held = 0 /\ tx = 0
    /\ Refill(posted, free)
    /\ UNCHANGED <<held, kept, tx, txkeep>>

(* net_rx_release. *)
Release ==
    /\ held = 1
    /\ Refill(posted, free + 1)
    /\ held' = 0
    /\ UNCHANGED <<kept, tx, txkeep>>

(* net_transmit: the held packet goes out as the reply. *)
Reply ==
    /\ held = 1
    /\ held' = 0
    /\ tx' = 1
    /\ txkeep' = 0
    /\ UNCHANGED <<posted, free, kept>>

(* net_transmit_ready, and net_transmit_keep refused: a kernel-built     *)
(* frame in a Free buffer.                                                *)
SendBuilt ==
    /\ held = 0 /\ tx = 0
    /\ free > 0
    /\ free' = free - 1
    /\ tx' = 1
    /\ txkeep' = 0
    /\ UNCHANGED <<posted, held, kept>>

(* net_transmit_keep accepted (net_tx_keep_slot): the same send, kept at *)
(* completion.                                                            *)
SendKept ==
    /\ held = 0 /\ tx = 0
    /\ free > 0
    /\ N - (kept + 1) >= RESERVE
    /\ free' = free - 1
    /\ tx' = 1
    /\ txkeep' = 1
    /\ UNCHANGED <<posted, held, kept>>

(* net_packet_kept_claim, then net_packet_kept_resend: a kept segment     *)
(* retransmitted in place.                                                *)
Resend ==
    /\ held = 0 /\ tx = 0
    /\ kept > 0
    /\ kept' = kept - 1
    /\ tx' = 1
    /\ txkeep' = 1
    /\ UNCHANGED <<posted, free, held>>

(* virtio_net_tx_finish / gem_tx_finish, then the refill: the buffer     *)
(* returns kept or Free.                                                  *)
TxComplete ==
    /\ tx = 1
    /\ IF txkeep = 1
       THEN /\ kept' = kept + 1
            /\ Refill(posted, free)
       ELSE /\ kept' = kept
            /\ Refill(posted, free + 1)
    /\ tx' = 0
    /\ txkeep' = 0
    /\ UNCHANGED held

(* net_packet_free, on any core and outside any RX turn: the buffer goes *)
(* back to its pool slot; the ring is not touched.                       *)
FreeKept ==
    /\ kept > 0
    /\ kept' = kept - 1
    /\ free' = free + 1
    /\ UNCHANGED <<posted, held, tx, txkeep>>

Next ==
    \/ Acquire \/ Poll \/ Release \/ Reply
    \/ SendBuilt \/ SendKept \/ Resend \/ TxComplete \/ FreeKept

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ posted \in 0..D /\ free \in 0..N /\ held \in 0..1
    /\ kept \in 0..N /\ tx \in 0..1 /\ txkeep \in 0..1

Conserved == posted + free + held + kept + tx = N

(* At least one RX descriptor is always posted. *)
RingNeverDrains == posted >= 1

(* Between turns a kernel-built frame always finds a Free buffer. *)
TxNeverStarves == (held = 0 /\ tx = 0) => free >= 1

Safety ==
    /\ TypeOK
    /\ Conserved
    /\ RingNeverDrains
    /\ TxNeverStarves

CInitFixed == N = 10 /\ D = 8 /\ RESERVE = 9
CInitGem == N = 4 /\ D = 1 /\ RESERVE = 2
CInitReserveD == N = 4 /\ D = 2 /\ RESERVE = 2
CInitNoReserve == N = 4 /\ D = 1 /\ RESERVE = 0
=============================================================================
