--------------------------- MODULE PacketReserve ---------------------------
(***************************************************************************)
(* The RX ring of a packet pool never drains (#740, the RX capability      *)
(* split). The stack may keep a received packet past its RX turn          *)
(* (net_rx_keep); the kept owner's free only returns the buffer to the    *)
(* pool, and only the RX capability's holder refills the ring. If kept    *)
(* packets could take every buffer, the ring would empty, no frame would   *)
(* arrive, no acquire would run, and nothing would refill it: a stall.    *)
(*                                                                         *)
(* Counts only: N pool buffers, D RX descriptors. A buffer is posted (an  *)
(* RX descriptor holds it), free, held (the one packet of the current RX  *)
(* turn), kept, or in TX (a reply or a kernel-built frame, completed      *)
(* within the turn that sent it). Keeping is refused when it would leave  *)
(* fewer than RESERVE buffers outside the kept set; the caller then       *)
(* copies and releases.                                                    *)
(*                                                                         *)
(* RESERVE 2 is the driver's (VIRTIO_PKT_RESERVE, GEM_PKT_RESERVE).        *)
(* Controls (a 4-buffer pool, 3 descriptors, for a short trace): RESERVE *)
(* 1 and RESERVE 0 drain the ring.                                       *)
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
    tx

\* @type: <<Int, Int, Int, Int, Int>>;
vars == <<posted, free, held, kept, tx>>

Min(a, b) == IF a < b THEN a ELSE b

Init ==
    /\ posted = D
    /\ free = N - D
    /\ held = 0
    /\ kept = 0
    /\ tx = 0

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
    /\ UNCHANGED <<kept, tx>>

(* net_rx_acquire's None path: no frame, but the holder still refills    *)
(* what off-turn frees returned.                                          *)
Poll ==
    /\ held = 0 /\ tx = 0
    /\ Refill(posted, free)
    /\ UNCHANGED <<held, kept, tx>>

(* net_rx_release, also the refused keep after its copy. *)
Release ==
    /\ held = 1
    /\ Refill(posted, free + 1)
    /\ held' = 0
    /\ UNCHANGED <<kept, tx>>

(* net_rx_keep: the packet leaves the turn; the capability returns. *)
Keep ==
    /\ held = 1
    /\ N - (kept + 1) >= RESERVE
    /\ held' = 0
    /\ kept' = kept + 1
    /\ UNCHANGED <<posted, free, tx>>

(* net_transmit: the held packet goes out as the reply. *)
Reply ==
    /\ held = 1
    /\ held' = 0
    /\ tx' = 1
    /\ UNCHANGED <<posted, free, kept>>

(* net_transmit_ready: a kernel-built frame in a Free buffer. *)
SendBuilt ==
    /\ held = 0 /\ tx = 0
    /\ free > 0
    /\ free' = free - 1
    /\ tx' = 1
    /\ UNCHANGED <<posted, held, kept>>

(* virtio_net_tx_finish / gem_tx_finish, then the refill. *)
TxComplete ==
    /\ tx = 1
    /\ Refill(posted, free + 1)
    /\ tx' = 0
    /\ UNCHANGED <<held, kept>>

(* net_packet_free, on any core and outside any RX turn: the buffer goes *)
(* back to its pool slot; the ring is not touched.                       *)
FreeKept ==
    /\ kept > 0
    /\ kept' = kept - 1
    /\ free' = free + 1
    /\ UNCHANGED <<posted, held, tx>>

Next ==
    \/ Acquire \/ Poll \/ Release \/ Keep \/ Reply
    \/ SendBuilt \/ TxComplete \/ FreeKept

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ posted \in 0..D /\ free \in 0..N /\ held \in 0..1
    /\ kept \in 0..N /\ tx \in 0..1

Conserved == posted + free + held + kept + tx = N

(* At least one RX descriptor is always posted. *)
RingNeverDrains == posted >= 1

Safety ==
    /\ TypeOK
    /\ Conserved
    /\ RingNeverDrains

CInitFixed == N = 10 /\ D = 8 /\ RESERVE = 2
CInitGem == N = 4 /\ D = 1 /\ RESERVE = 2
CInitReserveOne == N = 4 /\ D = 3 /\ RESERVE = 1
CInitNoReserve == N = 4 /\ D = 3 /\ RESERVE = 0
=============================================================================
