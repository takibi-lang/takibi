---------------------------- MODULE ConsoleTx ----------------------------
EXTENDS Integers, Sequences

(***************************************************************************)
(* Terminal output from any CPU onto one transmit queue (GitHub issue #663).*)
(*                                                                         *)
(* One process writes CHUNKS chunks to the terminal, one write(2) each, and *)
(* may run on core 0 or on a peer between writes. What reaches the wire has *)
(* to be in the order the process wrote it, and a writer that finds the     *)
(* queue full has to be woken when the transmit interrupt makes room.       *)
(*                                                                         *)
(* LOCKED = TRUE is the design under decision, option A: every CPU appends  *)
(* to the one queue in a critical section under one console lock, and the   *)
(* transmit interrupt takes bytes out under the same lock. Each action here *)
(* is one such critical section, so the queue order IS the lock order.      *)
(*                                                                         *)
(* LOCKED = FALSE is the kernel as it is: core 0 appends to the queue       *)
(* directly, and a peer publishes to its own ring, which core 0 moves into  *)
(* the queue at moments of its own (a syscall entry, a timer interrupt, an  *)
(* idle wake). A chunk written on a peer can therefore reach the queue after*)
(* a chunk written later on core 0. TLC must find ProgramOrder violated.    *)
(*                                                                         *)
(* RECHECK is the decide-then-sleep rule of GitHub issue #550 applied to    *)
(* the transmit queue: a writer decides "the queue is full, sleep" in one   *)
(* critical section and publishes itself asleep in a later one, and the     *)
(* transmit interrupt may drain the queue between them. With RECHECK = FALSE*)
(* the publication does not look at the queue again and the writer sleeps   *)
(* beside a queue with room. TLC must find NoLostWakeup violated.           *)
(*                                                                         *)
(* NESTED = TRUE is the lock-order defect the design must not have: the    *)
(* transmit interrupt keeps the console lock while it takes the run lock to *)
(* wake the sleeping writer. A writer that came into the syscall first holds*)
(* the run lock and wants the console lock, so each waits for the other.    *)
(* TLC must find the deadlock. The fixed order is run -> console, and the   *)
(* interrupt lets go of the console lock before it takes the run lock.      *)
(*                                                                         *)
(* The transmit queue holds QCAP chunks and a peer ring RCAP. Bytes within a*)
(* chunk are not modelled: a chunk is one indivisible append, as a whole    *)
(* user-output chunk is admitted under the run guard.                       *)
(*                                                                         *)
(* kernel/models/README.md maps each action to the functions it abstracts.  *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    LOCKED,
    \* @type: Bool;
    RECHECK,
    \* @type: Bool;
    NESTED

CHUNKS == 3
QCAP == 1
RCAP == 2

VARIABLES
    \* @type: Int;
    nextChunk,   \* the next chunk the writer will write, 1 .. CHUNKS + 1
    \* @type: Int;
    loc,         \* the CPU the writer runs on: 0 is core 0, 1 a peer
    \* @type: Str;
    pc,          \* the writer: "idle" | "inrun" | "decided" | "asleep"
    \* @type: Str;
    runLock,     \* the process-run lock: "free" | "writer" | "isr"
    \* @type: Str;
    conLock,     \* the console lock: "free" | "isr" (a writer holds it only
                 \* inside its one append step)
    \* @type: Bool;
    wakePending, \* the interrupt made room and has not yet run its wake
    \* @type: Seq(Int);
    queue,       \* chunks in the transmit queue, oldest first
    \* @type: Seq(Int);
    ring,        \* chunks the peer has published and core 0 has not moved
    \* @type: Seq(Int);
    wire         \* chunks the transmit interrupt has sent, in order

vars == <<nextChunk, loc, pc, runLock, conLock, wakePending, queue, ring, wire>>

Init ==
    /\ nextChunk = 1
    /\ loc = 0
    /\ pc = "idle"
    /\ runLock = "free"
    /\ conLock = "free"
    /\ wakePending = FALSE
    /\ queue = <<>>
    /\ ring = <<>>
    /\ wire = <<>>

----------------------------------------------------------------------------
(* Actions *)

\* syscall_terminal_write admits the whole chunk under the process-run lock.
WriterEnter ==
    /\ pc = "idle"
    /\ nextChunk <= CHUNKS
    /\ runLock = "free"
    /\ runLock' = "writer"
    /\ pc' = "inrun"
    /\ UNCHANGED <<nextChunk, loc, conLock, wakePending, queue, ring, wire>>

\* uart_user_write: with the run lock held, append this chunk to the queue in
\* one critical section under the console lock, or decide the queue has no
\* room and the writer must sleep. On a peer and not LOCKED it publishes to
\* the peer ring instead, which takes no console lock; a full ring takes
\* nothing and the write retries. Either way the run lock is let go.
WriterAppend ==
    /\ pc = "inrun"
    /\ runLock = "writer"
    /\ runLock' = "free"
    /\ IF LOCKED \/ loc = 0
         THEN /\ conLock = "free"
              /\ IF Len(queue) < QCAP
                    THEN /\ queue' = Append(queue, nextChunk)
                         /\ nextChunk' = nextChunk + 1
                         /\ pc' = "idle"
                    ELSE /\ pc' = "decided"
                         /\ UNCHANGED <<queue, nextChunk>>
              /\ UNCHANGED ring
         ELSE /\ IF Len(ring) < RCAP
                    THEN /\ ring' = Append(ring, nextChunk)
                         /\ nextChunk' = nextChunk + 1
                    ELSE UNCHANGED <<ring, nextChunk>>
              /\ pc' = "idle"
              /\ UNCHANGED <<queue>>
    /\ UNCHANGED <<loc, conLock, wakePending, wire>>

\* kernel_process_block_uart_tx: publish the writer asleep (under the run
\* lock), and switch away. With RECHECK the publication looks at the queue
\* again under the lock the waker takes and reruns the write if there is
\* room now.
BlockWriter ==
    /\ pc = "decided"
    /\ runLock = "free"
    /\ IF RECHECK /\ Len(queue) < QCAP
         THEN pc' = "idle"
         ELSE pc' = "asleep"
    /\ UNCHANGED <<nextChunk, loc, runLock, conLock, wakePending, queue, ring, wire>>

\* uart_tx_service: take the oldest chunk off the queue onto the wire under the
\* console lock, and note that there is room. Fixed, the console lock is let
\* go here; NESTED, it is kept until the wake has run.
TxTake ==
    /\ queue # <<>>
    /\ conLock = "free"
    /\ wire' = Append(wire, Head(queue))
    /\ queue' = Tail(queue)
    /\ wakePending' = TRUE
    /\ conLock' = IF NESTED THEN "isr" ELSE "free"
    /\ UNCHANGED <<nextChunk, loc, pc, runLock, ring>>

\* kernel_process_uart_tx_wake_all, from the interrupt: under the run lock, a
\* writer asleep on room is made runnable.
TxWake ==
    /\ wakePending
    /\ runLock = "free"
    /\ wakePending' = FALSE
    /\ conLock' = "free"
    /\ pc' = IF pc = "asleep" THEN "idle" ELSE pc
    /\ UNCHANGED <<nextChunk, loc, runLock, queue, ring, wire>>

\* kernel_log_peer_console_drain: core 0 moves the oldest ring chunk into
\* the queue. Only the ring design has a ring. Core 0 does this at moments of
\* its own, so it is an action that may happen or not between any two others.
Drain ==
    /\ ~LOCKED
    /\ ring # <<>>
    /\ Len(queue) < QCAP
    /\ queue' = Append(queue, Head(ring))
    /\ ring' = Tail(ring)
    /\ UNCHANGED <<nextChunk, loc, pc, runLock, conLock, wakePending, wire>>

\* The scheduler moves the process between writes (never inside one: the
\* kernel is not preemptible in a syscall).
Migrate ==
    /\ pc = "idle"
    /\ loc' = 1 - loc
    /\ UNCHANGED <<nextChunk, pc, runLock, conLock, wakePending, queue, ring, wire>>

\* Everything written and sent: a stuttering step, so a stuck writer shows as
\* a deadlock rather than as the model ending.
Finished ==
    /\ nextChunk = CHUNKS + 1
    /\ queue = <<>>
    /\ ring = <<>>
    /\ ~wakePending
    /\ UNCHANGED vars

Next ==
    \/ WriterEnter
    \/ WriterAppend
    \/ BlockWriter
    \/ TxTake
    \/ TxWake
    \/ Drain
    \/ Migrate
    \/ Finished

\* The transmit interrupt and the ring drain keep happening while there is
\* something for them to do, and the writer keeps getting to run.
Fairness ==
    /\ WF_vars(WriterEnter)
    /\ WF_vars(WriterAppend)
    /\ WF_vars(BlockWriter)
    /\ WF_vars(TxTake)
    /\ WF_vars(TxWake)
    /\ WF_vars(Drain)

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ nextChunk \in 1 .. CHUNKS + 1
    /\ loc \in 0 .. 1
    /\ pc \in {"idle", "inrun", "decided", "asleep"}
    /\ runLock \in {"free", "writer", "isr"}
    /\ conLock \in {"free", "isr"}
    /\ Len(queue) <= QCAP
    /\ Len(ring) <= RCAP

\* What reaches the wire is in the order the process wrote it.
ProgramOrder ==
    \A i \in 1 .. Len(wire) : \A j \in 1 .. Len(wire) :
        i < j => wire[i] < wire[j]

\* The writer is never asleep while the queue has room and no wake is on its way: nothing would wake it
\* until the next transmit interrupt, and that may never come.
NoLostWakeup ==
    ~(pc = "asleep" /\ Len(queue) < QCAP /\ ~wakePending)

\* Both safety properties, for the one invariant Apalache checks per model.
Safety == ProgramOrder /\ NoLostWakeup

\* Every chunk is written and sent.
AllSent == <>(nextChunk = CHUNKS + 1 /\ queue = <<>> /\ ring = <<>>)

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE
CInitRing == LOCKED = FALSE /\ RECHECK = TRUE /\ NESTED = FALSE
CInitNoRecheck == LOCKED = TRUE /\ RECHECK = FALSE /\ NESTED = FALSE
CInitNested == LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = TRUE

=============================================================================
