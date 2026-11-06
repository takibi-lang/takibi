----------------------------- MODULE TcpAccept -----------------------------
(***************************************************************************)
(* The TCP accept handshake with a delayed or lost peer ACK (GitHub issue  *)
(* #1371, after #876).                                                     *)
(*                                                                         *)
(* One listener (kernel_tcp_accept_step) and one peer. The peer sends a    *)
(* SYN, the listener answers SYN-ACK and retransmits it RETRIES times;     *)
(* past that it gives up and goes back to Listen. Since #876 it remembers  *)
(* the abandoned handshake (accept_syn_ack_retries = TCP_ACCEPT_ABANDONED) *)
(* and a late final ACK that matches it completes it. The network may     *)
(* delay any segment (it stays in flight while other steps run) or lose   *)
(* it. A segment for the listener is taken either by the accept step      *)
(* itself or by another receive waiter that holds RX                      *)
(* (tcp_route_received_segment), which completes a half-open handshake    *)
(* for the parked accept.                                                  *)
(*                                                                         *)
(* REMEMBER = FALSE is the kernel before #876: the give-up forgets the     *)
(* handshake, and TLC must find NoForgottenPeer violated. ROUTEABANDONED   *)
(* = FALSE is the route path that completes only SynRcvd: a late ACK      *)
(* another waiter takes while the handshake is abandoned is dropped, and   *)
(* TLC must find DeliveredAckCompletes violated.                           *)
(*                                                                         *)
(* GitHub issue #1399: another waiter that finds the listener's connection *)
(* Busy (another CPU holds its lock) drops the frame (BusyDrop). Before   *)
(* the give-up the next SYN-ACK retransmission draws the ACK again; after *)
(* it nothing does. ABANDONRETX = FALSE is the kernel as it is: with no    *)
(* network loss and one Busy drop, TLC must find AckReachesListener (the  *)
(* peer's connection completes) violated. ABANDONRETX = TRUE keeps         *)
(* retransmitting SYN-ACK after the give-up, as Linux's request socket    *)
(* does, while a new SYN may still take the listener.                     *)
(*                                                                         *)
(* Each action is one acquire of a received frame, or one pass of the     *)
(* retransmission timer, in the kernel; kernel/models/README.md maps them. *)
(***************************************************************************)

EXTENDS Naturals

CONSTANT
    \* @type: Bool;
    REMEMBER,
    \* @type: Bool;
    ROUTEABANDONED,
    \* @type: Bool;
    ABANDONRETX,
    \* @type: Bool;
    NETLOSS

\* TCP_RETRY_LIMIT.
RETRIES == 2

VARIABLES
    \* @type: Str;
    lst,     \* listener: "Listen" | "SynRcvd" | "Abandoned" | "Established"
    \* @type: Int;
    retries, \* SYN-ACK retransmissions sent for this handshake
    \* @type: Str;
    peer,    \* "Closed" | "SynSent" | "Connected"
    \* @type: Set(Str);
    toL,     \* segments in flight to the listener: "SYN", "ACK"
    \* @type: Set(Str);
    toP,     \* segments in flight to the peer: "SYNACK"
    \* @type: Bool;
    dropped, \* a matching ACK reached a receiver and did not complete
    \* @type: Int;
    synsent, \* SYNs the peer has sent, bounded
    \* @type: Int;
    aretries, \* SYN-ACKs retransmitted after the give-up (#1399)
    \* @type: Int;
    busy     \* frames another waiter dropped on a Busy connection, bounded

vars == <<lst, retries, peer, toL, toP, dropped, synsent, aretries, busy>>

MAXSYN == 2
\* Retransmissions after the give-up, and Busy drops: one each is enough to
\* show the loss and its recovery.
ARETRIES == 1
MAXBUSY == 1

\* A handshake the listener can still complete on the peer's ACK.
Completable == lst = "SynRcvd" \/ lst = "Abandoned"

Init ==
    /\ lst = "Listen"
    /\ retries = 0
    /\ peer = "Closed"
    /\ toL = {}
    /\ toP = {}
    /\ dropped = FALSE
    /\ synsent = 0
    /\ aretries = 0
    /\ busy = 0

----------------------------------------------------------------------------
(* The peer *)

\* connect(): the first SYN, or a retransmission while no SYN-ACK came.
PeerSyn ==
    /\ peer \in {"Closed", "SynSent"}
    /\ synsent < MAXSYN
    /\ peer' = "SynSent"
    /\ toL' = toL \union {"SYN"}
    /\ synsent' = synsent + 1
    /\ UNCHANGED <<lst, retries, toP, dropped, aretries, busy>>

\* A SYN-ACK arrives: the peer is connected and sends the final ACK; a
\* duplicate SYN-ACK while connected is answered with the ACK again.
PeerSynAck ==
    /\ "SYNACK" \in toP
    /\ peer \in {"SynSent", "Connected"}
    /\ peer' = "Connected"
    /\ toP' = toP \ {"SYNACK"}
    /\ toL' = toL \union {"ACK"}
    /\ UNCHANGED <<lst, retries, dropped, synsent, aretries, busy>>

----------------------------------------------------------------------------
(* The listener *)

\* The accept step acquires one frame for its port.
\* @type: (Str) => Bool;
StepRecv(s) ==
    /\ s \in toL
    /\ toL' = toL \ {s}
    /\ IF s = "SYN"
         THEN IF lst \in {"Listen", "Abandoned"}
                THEN /\ lst' = "SynRcvd"
                     /\ retries' = 0
                     /\ aretries' = 0
                     /\ toP' = toP \union {"SYNACK"}
                ELSE UNCHANGED <<lst, retries, toP, aretries>>
         ELSE IF Completable
                THEN /\ lst' = "Established"
                     /\ UNCHANGED <<retries, toP, aretries>>
                ELSE UNCHANGED <<lst, retries, toP, aretries>>
    /\ UNCHANGED <<peer, dropped, synsent, busy>>

\* Another receive waiter holds RX and routes the frame
\* (tcp_route_received_segment): it completes a half-open handshake and
\* drops anything else for this listener.
\* @type: (Str) => Bool;
OtherRecv(s) ==
    /\ s \in toL
    /\ toL' = toL \ {s}
    /\ IF s = "ACK" /\ (lst = "SynRcvd" \/ (ROUTEABANDONED /\ lst = "Abandoned"))
         THEN /\ lst' = "Established"
              /\ UNCHANGED dropped
         ELSE /\ dropped' = (dropped \/ (s = "ACK" /\ Completable))
              /\ UNCHANGED lst
    /\ UNCHANGED <<retries, peer, toP, synsent, aretries, busy>>

\* The retransmission timer: another SYN-ACK, or past the limit, give up.
Retry ==
    /\ lst = "SynRcvd"
    /\ IF retries < RETRIES
         THEN /\ retries' = retries + 1
              /\ toP' = toP \union {"SYNACK"}
              /\ UNCHANGED lst
         ELSE /\ lst' = IF REMEMBER THEN "Abandoned" ELSE "Listen"
              /\ UNCHANGED <<retries, toP>>
    /\ UNCHANGED <<peer, toL, dropped, synsent, aretries, busy>>

\* #1399: after the give-up, with ABANDONRETX, the timer keeps
\* retransmitting the remembered SYN-ACK a bounded number of times.
AbandonedRetry ==
    /\ ABANDONRETX
    /\ lst = "Abandoned"
    /\ aretries < ARETRIES
    \* Its backed-off period outlasts a round trip: it fires once the last
    \* exchange has settled (answered, dropped or lost). Without this, any
    \* bounded number of retransmissions loses to a slow enough peer, as
    \* Linux's does.
    /\ "SYNACK" \notin toP
    /\ "ACK" \notin toL
    /\ aretries' = aretries + 1
    /\ toP' = toP \union {"SYNACK"}
    /\ UNCHANGED <<lst, retries, peer, toL, dropped, synsent, busy>>

\* #1399: another waiter finds the listener's connection Busy and drops the
\* frame (tcp_connection_try_take answers Busy).
\* @type: (Str) => Bool;
BusyDrop(s) ==
    /\ s \in toL
    /\ busy < MAXBUSY
    /\ toL' = toL \ {s}
    /\ busy' = busy + 1
    /\ UNCHANGED <<lst, retries, peer, toP, dropped, synsent, aretries>>

----------------------------------------------------------------------------
(* The network loses a segment in flight. *)

\* @type: (Str) => Bool;
LoseToL(s) ==
    /\ NETLOSS
    /\ s \in toL
    /\ toL' = toL \ {s}
    /\ UNCHANGED <<lst, retries, peer, toP, dropped, synsent, aretries, busy>>

LoseToP ==
    /\ NETLOSS
    /\ "SYNACK" \in toP
    /\ toP' = toP \ {"SYNACK"}
    /\ UNCHANGED <<lst, retries, peer, toL, dropped, synsent, aretries, busy>>

Next ==
    \/ PeerSyn
    \/ PeerSynAck
    \/ \E s \in {"SYN", "ACK"} :
           StepRecv(s) \/ OtherRecv(s) \/ LoseToL(s) \/ BusyDrop(s)
    \/ Retry
    \/ AbandonedRetry
    \/ LoseToP

\* The timers fire, frames in flight are taken, the peer answers. Losses
\* and Busy drops are not forced.
Fairness ==
    /\ WF_vars(Retry)
    /\ WF_vars(AbandonedRetry)
    /\ WF_vars(PeerSynAck)
    /\ WF_vars(PeerSyn)
    /\ \A s \in {"SYN", "ACK"} : WF_vars(StepRecv(s) \/ OtherRecv(s))

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ lst \in {"Listen", "SynRcvd", "Abandoned", "Established"}
    /\ retries \in 0..RETRIES
    /\ peer \in {"Closed", "SynSent", "Connected"}
    /\ toL \subseteq {"SYN", "ACK"}
    /\ toP \subseteq {"SYNACK"}
    /\ dropped \in BOOLEAN
    /\ synsent \in 0..MAXSYN
    /\ aretries \in 0..ARETRIES
    /\ busy \in 0..MAXBUSY

\* #876: a peer that saw a SYN-ACK and counts itself connected is never
\* forgotten: the listener still holds its handshake, or has completed it.
NoForgottenPeer ==
    peer = "Connected" => lst \in {"SynRcvd", "Abandoned", "Established"}

\* #1371: a final ACK that reaches either receiver while the handshake can
\* still complete completes it. Only the network may lose it.
DeliveredAckCompletes == ~dropped

\* #1399, liveness (TLC only), checked without network loss: a peer that
\* is connected is eventually the listener's established connection,
\* whatever one transient Busy drop took.
AckReachesListener == (peer = "Connected") ~> (lst = "Established")

Safety == TypeOK /\ NoForgottenPeer /\ DeliveredAckCompletes

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == REMEMBER = TRUE /\ ROUTEABANDONED = TRUE /\
    ABANDONRETX = TRUE /\ NETLOSS = TRUE
CInitForget == REMEMBER = FALSE /\ ROUTEABANDONED = TRUE /\
    ABANDONRETX = TRUE /\ NETLOSS = TRUE
CInitRouteSynRcvd == REMEMBER = TRUE /\ ROUTEABANDONED = FALSE /\
    ABANDONRETX = TRUE /\ NETLOSS = TRUE
CInitBusy == REMEMBER = TRUE /\ ROUTEABANDONED = TRUE /\
    ABANDONRETX = TRUE /\ NETLOSS = FALSE
CInitBusyNoRetx == REMEMBER = TRUE /\ ROUTEABANDONED = TRUE /\
    ABANDONRETX = FALSE /\ NETLOSS = FALSE

=============================================================================
