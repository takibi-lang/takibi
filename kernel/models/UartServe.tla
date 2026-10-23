------------------------------ MODULE UartServe ------------------------------
EXTENDS Integers

(***************************************************************************)
(* The UART interrupt under GICv2 1-of-N delivery, served by one core at a *)
(* time through a try-lock (GitHub issues #830 and #925).                  *)
(*                                                                         *)
(* kernel/kernel/uart_irq_affinity.tkb routes the UART SPI to every online *)
(* core. Each core that takes it runs uart_irq_serve: a compare-swap of    *)
(* uart_irq_service_busy from 0 to 1; the loser EOIs and returns, the       *)
(* winner runs uart_irq_service (TX refill, then RX drain to RXFE), clears *)
(* the word, and EOIs. Nothing is lost by leaving only because every       *)
(* source is level: whatever the busy core did not drain keeps the line    *)
(* asserted, so the interrupt is pending again.                            *)
(*                                                                         *)
(* EDGE = TRUE is the design that comment rules out: the interrupt is      *)
(* latched pending only on a rising line, and a delivery consumes it. A    *)
(* byte that arrives after the winner's drain is delivered to a core that  *)
(* finds the service busy and leaves; the winner releases, and the byte    *)
(* waits with no core serving and nothing pending. TLC must find          *)
(* NoStranded violated.                                                    *)
(*                                                                         *)
(* GATE = TRUE is GICv2's active state: an SPI that is active on one core  *)
(* is not signalled to another until that core's EOI. The kernel releases  *)
(* the word before its EOI, so under the gate the try-lock is never        *)
(* contended (TryLockBusy is dead; see coverage_allow.txt). GATE = FALSE   *)
(* drops the gate, the conservative reading uart_irq_affinity.tkb's        *)
(* comment takes ("a GIC may hand the next interrupt to another core while *)
(* the first is still inside the handler"), and is the variant that        *)
(* exercises the try-lock.                                                  *)
(*                                                                         *)
(* kernel/models/README.md maps each action to the functions it abstracts.  *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    EDGE,
    \* @type: Bool;
    GATE

CPUS == {1, 2, 3}
RXMAX == 2        \* bytes the model's FIFO holds
ARRIVALS == 3     \* RX bytes and TX-space events, in all, per behaviour

VARIABLES
    \* @type: Int;
    rx,          \* bytes in the RX FIFO
    \* @type: Bool;
    tx,          \* TX FIFO below its level with the queue non-empty
    \* @type: Int;
    arrived,     \* source events so far, bounded by ARRIVALS
    \* @type: Bool;
    pend,        \* EDGE only: the GIC's latched pending bit
    \* @type: Bool;
    act,         \* the SPI is active on some core (taken, not yet EOI'd)
    \* @type: Int;
    busy,        \* uart_irq_service_busy: 0, or the core inside the service
    \* @type: Int -> Str;
    pc           \* "idle" | "lock" | "serve" | "rx" | "release" | "eoi"

vars == <<rx, tx, arrived, pend, act, busy, pc>>

\* The PL011's interrupt line: some enabled source is asserted.
Line == rx > 0 \/ tx

\* What the GIC can deliver: a level SPI is pending while the line is up.
Pending == IF EDGE THEN pend ELSE Line

Init ==
    /\ rx = 0
    /\ tx = FALSE
    /\ arrived = 0
    /\ pend = FALSE
    /\ act = FALSE
    /\ busy = 0
    /\ pc = [c \in CPUS |-> "idle"]

\* A byte reaches the RX FIFO (RX or RX-timeout asserts).
ArriveRx ==
    /\ arrived < ARRIVALS
    /\ rx < RXMAX
    /\ rx' = rx + 1
    /\ arrived' = arrived + 1
    /\ pend' = (pend \/ (EDGE /\ ~Line))
    /\ UNCHANGED <<tx, act, busy, pc>>

\* A writer queues output while the TX FIFO is below its level.
ArriveTx ==
    /\ arrived < ARRIVALS
    /\ ~tx
    /\ tx' = TRUE
    /\ arrived' = arrived + 1
    /\ pend' = (pend \/ (EDGE /\ ~Line))
    /\ UNCHANGED <<rx, act, busy, pc>>

\* The GIC hands the SPI to one core of the route, which acknowledges it.
Deliver(c) ==
    /\ pc[c] = "idle"
    /\ Pending
    /\ GATE => ~act
    /\ act' = TRUE
    /\ pend' = FALSE
    /\ pc' = [pc EXCEPT ![c] = "lock"]
    /\ UNCHANGED <<rx, tx, arrived, busy>>

\* uart_irq_serve: the compare-swap wins.
TryLockWin(c) ==
    /\ pc[c] = "lock"
    /\ busy = 0
    /\ busy' = c
    /\ pc' = [pc EXCEPT ![c] = "serve"]
    /\ UNCHANGED <<rx, tx, arrived, pend, act>>

\* uart_irq_serve: the compare-swap finds another core inside; leave.
TryLockBusy(c) ==
    /\ pc[c] = "lock"
    /\ busy # 0
    /\ pc' = [pc EXCEPT ![c] = "eoi"]
    /\ UNCHANGED <<rx, tx, arrived, pend, act, busy>>

\* uart_irq_service's TX half: refill the FIFO above its level.
ServeTx(c) ==
    /\ pc[c] = "serve"
    /\ tx' = FALSE
    /\ pc' = [pc EXCEPT ![c] = "rx"]
    /\ UNCHANGED <<rx, arrived, pend, act, busy>>

\* uart_irq_service's RX half: drain to RXFE.
DrainRx(c) ==
    /\ pc[c] = "rx"
    /\ rx' = 0
    /\ pc' = [pc EXCEPT ![c] = "release"]
    /\ UNCHANGED <<tx, arrived, pend, act, busy>>

\* uart_irq_serve: store 0 to the busy word.
Release(c) ==
    /\ pc[c] = "release"
    /\ busy' = 0
    /\ pc' = [pc EXCEPT ![c] = "eoi"]
    /\ UNCHANGED <<rx, tx, arrived, pend, act>>

\* The dispatch's EOI (after RP1's IACK on RPi5).
Eoi(c) ==
    /\ pc[c] = "eoi"
    /\ act' = FALSE
    /\ pc' = [pc EXCEPT ![c] = "idle"]
    /\ UNCHANGED <<rx, tx, arrived, pend, busy>>

\* Every source event spent and nothing left to do: a stuttering step, so
\* the end is not a deadlock.
Done ==
    /\ arrived = ARRIVALS
    /\ ~Line
    /\ \A c \in CPUS : pc[c] = "idle"
    /\ UNCHANGED vars

Next ==
    \/ Done
    \/ ArriveRx
    \/ ArriveTx
    \/ \E c \in CPUS :
        \/ Deliver(c)
        \/ TryLockWin(c)
        \/ TryLockBusy(c)
        \/ ServeTx(c)
        \/ DrainRx(c)
        \/ Release(c)
        \/ Eoi(c)

Fairness ==
    /\ WF_vars(\E c \in CPUS : Deliver(c))
    /\ \A c \in CPUS :
        WF_vars(TryLockWin(c) \/ TryLockBusy(c) \/ ServeTx(c)
                \/ DrainRx(c) \/ Release(c) \/ Eoi(c))

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ rx \in 0 .. RXMAX
    /\ arrived \in 0 .. ARRIVALS
    /\ busy \in 0 .. 3
    /\ \A c \in CPUS :
        pc[c] \in {"idle", "lock", "serve", "rx", "release", "eoi"}

\* A source event is never left with no core about to serve it and no
\* delivery pending. A core still at "lock" counts: it either wins and
\* serves, or leaves, and then this is judged again.
NoStranded ==
    /\ (rx > 0 =>
          Pending \/ \E c \in CPUS : pc[c] \in {"lock", "serve", "rx"})
    /\ (tx =>
          Pending \/ \E c \in CPUS : pc[c] \in {"lock", "serve"})

\* At most one core inside the service.
OneServer ==
    \A c, d \in CPUS :
        (c # d /\ pc[c] \in {"serve", "rx", "release"}) =>
            pc[d] \notin {"serve", "rx", "release"}

Safety == TypeOK /\ NoStranded /\ OneServer

\* Once the sources stop, everything that arrived is served.
Quiesces == <>[](rx = 0 /\ ~tx)

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == EDGE = FALSE /\ GATE = FALSE
CInitGated == EDGE = FALSE /\ GATE = TRUE
CInitEdge == EDGE = TRUE /\ GATE = FALSE
=============================================================================
