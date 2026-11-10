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
(* LOCKED = TRUE is the maintained shared-queue design: every CPU appends  *)
(* to the one queue in a critical section under one console lock, and the   *)
(* transmit interrupt takes bytes out under the same lock. Each action here *)
(* is one such critical section, so the queue order IS the lock order.      *)
(*                                                                         *)
(* LOCKED = FALSE reproduces the former kernel: core 0 appends to the queue       *)
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
(* POLLWAKE is GitHub issue #1211: a drain that is not the transmit       *)
(* interrupt's own (the RX handler's resume drain, a kernel log line's      *)
(* drain) can also make the room a sleeping writer waits for, and only the  *)
(* interrupt path wakes writers. With POLLWAKE = TRUE such a drain keeps the*)
(* interrupt enabled, so its service runs the wake; with POLLWAKE = FALSE a *)
(* drain that empties the queue leaves nothing to send, the interrupt stays *)
(* off, and the writer sleeps beside an empty queue. TLC must find          *)
(* NoLostWakeup violated.                                                   *)
(*                                                                         *)
(* The transmit queue holds QCAP chunks and a peer ring RCAP. Bytes within a*)
(* chunk are not modelled: a chunk is one indivisible append, as a whole    *)
(* user-output chunk is admitted under the run guard.                       *)
(*                                                                         *)
(* PREEMPTIBLE = TRUE is the #638 flip (stage 9): a tick may also move the *)
(* writer between its decision and its sleep, two critical sections with no *)
(* lock held between them. The fixed design must pass either way.          *)
(*                                                                         *)
(* kernel/models/README.md maps each action to the functions it abstracts.  *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    LOCKED,
    \* @type: Bool;
    RECHECK,
    \* @type: Bool;
    NESTED,
    \* @type: Bool;
    POLLWAKE,
    \* @type: Bool;
    PREEMPTIBLE,
    \* @type: Bool;
    FLOW,
    \* @type: Bool;
    FLOWKICK,
    \* @type: Bool;
    FLOWFENCE,
    \* @type: Bool;
    FLOWCOMPACT,
    \* @type: Bool;
    FLOWHINT,
    \* @type: Bool;
    FLOWREARM,
    \* @type: Bool;
    FLOWOWNERSAFE,
    \* @type: Bool;
    FLOWPAUSE,
    \* @type: Bool;
    FLOWSTOPDISABLED,
    \* @type: Bool;
    FLOWSTARTDISABLED,
    \* @type: Bool;
    FLOWWORK

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



VARIABLES
    \* @type: Seq(Int);
    fQueue,
    \* @type: Int;
    fNext,
    \* @type: Seq(Int);
    fWire,
    \* @type: Seq(Bool);
    fControls,
    \* @type: Int;
    fRequests,
    \* @type: Bool;
    fWanted,
    \* @type: Bool;
    fSent,
    \* @type: Bool;
    fCapture,
    \* @type: Bool;
    fPending,
    \* @type: Int;
    fBefore,
    \* @type: Int;
    fBarrier,
    \* @type: Bool;
    fHint,
    \* @type: Bool;
    fIrq,
    \* @type: Str;
    fPhase,
    \* @type: Str;
    fActor,
    \* @type: Str;
    fOwner,
    \* @type: Bool;
    fStopSeen,
    \* @type: Bool;
    fTerminal,
    \* @type: Bool;
    fPaused,
    \* @type: Int;
    fPauseStage,
    \* @type: Bool;
    fHoldSeen,
    \* @type: Bool;
    fInFlight,
    \* @type: Bool;
    fOrderGood,
    \* @type: Str;
    fAuxKind,
    \* @type: Bool;
    fAuxOffered,
    \* @type: Bool;
    fEcho,
    \* @type: Bool;
    fWake

writerVars == <<nextChunk, loc, pc, runLock, conLock, wakePending, queue, ring, wire>>


flowVars == <<fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fIrq, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>
vars == <<writerVars, flowVars>>

WriterInit ==
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
    /\ UNCHANGED flowVars
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
    /\ UNCHANGED flowVars
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
    /\ UNCHANGED flowVars
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
    /\ UNCHANGED flowVars
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
    /\ UNCHANGED flowVars
    /\ wakePending
    /\ runLock = "free"
    /\ wakePending' = FALSE
    /\ conLock' = "free"
    /\ pc' = IF pc = "asleep" THEN "idle" ELSE pc
    /\ UNCHANGED <<nextChunk, loc, runLock, queue, ring, wire>>

\* uart_terminal_resume_output, uart_wire_byte, kernel_log_emit_line: a drain
\* outside the transmit interrupt takes the oldest chunk onto the wire under
\* the console lock. It cannot take the run lock (run -> console), so it does
\* not wake; with POLLWAKE it owes the wake and keeps the interrupt enabled,
\* whose service then runs TxWake.
PollDrain ==
    /\ UNCHANGED flowVars
    /\ queue # <<>>
    /\ conLock = "free"
    /\ wire' = Append(wire, Head(queue))
    /\ queue' = Tail(queue)
    /\ wakePending' = (wakePending \/ POLLWAKE)
    /\ UNCHANGED <<nextChunk, loc, pc, runLock, conLock, ring>>

\* kernel_log_peer_console_drain: core 0 moves the oldest ring chunk into
\* the queue. Only the ring design has a ring. Core 0 does this at moments of
\* its own, so it is an action that may happen or not between any two others.
Drain ==
    /\ UNCHANGED flowVars
    /\ ~LOCKED
    /\ ring # <<>>
    /\ Len(queue) < QCAP
    /\ queue' = Append(queue, Head(ring))
    /\ ring' = Tail(ring)
    /\ UNCHANGED <<nextChunk, loc, pc, runLock, conLock, wakePending, wire>>

\* The scheduler moves the process between writes; with PREEMPTIBLE (the #638
\* flip) also between a write's decision and its sleep, where it holds no
\* lock. Never inside a critical section: those hold a masking lock.
Migrate ==
    /\ UNCHANGED flowVars
    /\ pc \in (IF PREEMPTIBLE THEN {"idle", "decided"} ELSE {"idle"})
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

WriterNext ==
    \/ WriterEnter
    \/ WriterAppend
    \/ BlockWriter
    \/ TxTake
    \/ TxWake
    \/ PollDrain
    \/ Drain
    \/ Migrate
    \/ Finished

\* The transmit interrupt and the ring drain keep happening while there is
\* something for them to do, and the writer keeps getting to run.
WriterFairness ==
    /\ WF_vars(WriterEnter)
    /\ WF_vars(WriterAppend)
    /\ WF_vars(BlockWriter)
    /\ WF_vars(TxTake)
    /\ WF_vars(TxWake)
    /\ WF_vars(Drain)



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

\* Every chunk is written and sent.
AllSent == <>(nextChunk = CHUNKS + 1 /\ queue = <<>> /\ ring = <<>>)

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)


----------------------------------------------------------------------------
(* Input-flow slice, independent of the original writer/wake controls.
   FLOW selects this slice; the other slice's variables stay fixed. Thus a
   new queue/ownership interaction does not multiply every old state space.

   Two queue slots, three admissions and three alternating requests cover a
   full queue, a later append, STOP/START coalescing and a final latest state.
   A queue value is 2*serial + terminal-tag: even values are kernel bytes.
   Positive wire values are queued data; -1/-2 are STOP/START identities.

   The publisher and consumer retain their real console guard across their
   phase actions. Only the complete-stop observer may interrupt these phases.
   It reads the atomic hint, never a coherent snapshot of the guarded fields.
   An unrelated holder models DDB's Busy flush without a later output kick.
   FIFO room and level IRQ delivery are fair external progress assumptions.
   ConsoleOwner separately checks priority/owner identity and sticky terminal
   ownership. Here terminal ownership must also prevent a flow IRQ rearm.
*)

FlowDefaults == FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\
                FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\
                FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = TRUE

FlowDisabled(wanted) == IF wanted THEN FLOWSTOPDISABLED ELSE FLOWSTARTDISABLED

FlowIdleInit ==
    /\ fQueue = <<>>
    /\ fNext = 1
    /\ fWire = <<>>
    /\ fControls = <<>>
    /\ fRequests = 0
    /\ fWanted = FALSE
    /\ fSent = FALSE
    /\ fCapture = FALSE
    /\ fPending = FALSE
    /\ fBefore = 0
    /\ fBarrier = 0
    /\ fHint = FALSE
    /\ fIrq = FALSE
    /\ fPhase = "idle"
    /\ fActor = "normal"
    /\ fOwner = "normal"
    /\ fStopSeen = FALSE
    /\ fTerminal = FALSE
    /\ fPaused = FALSE
    /\ fPauseStage = 0
    /\ fHoldSeen = FALSE
    /\ fInFlight = FALSE
    /\ fOrderGood = TRUE
    /\ fAuxKind \in (IF FLOW THEN {"none", "echo", "wake"} ELSE {"none"})
    /\ fAuxOffered = FALSE
    /\ fEcho = FALSE
    /\ fWake = FALSE

\* One bounded normal queue admission; serial 2 is terminal-tagged.
FlowAppend ==
    /\ fOwner = "normal"
    /\ fPhase = "idle"
    /\ ~fPaused
    /\ fNext <= 3
    /\ Len(fQueue) < 2
    /\ fQueue' = (Append(fQueue, 2*fNext + (IF fNext % 2 = 0 THEN 1 ELSE 0)))
    /\ fNext' = (fNext + 1)
    /\ fIrq' = (TRUE)
    /\ UNCHANGED <<writerVars, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Acquire the console guard and publish the atomic hint before pending metadata.
FlowBegin ==
    /\ fOwner = "normal"
    /\ fPhase = "idle"
    /\ fRequests < 3
    /\ fCapture' = (~fWanted)
    /\ fHint' = (IF FLOWHINT /\ ~FlowDisabled(~fWanted) THEN TRUE ELSE fHint)
    /\ fPhase' = ("hinted")
    /\ fActor' = ("normal")
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fPending, fBefore, fBarrier, fIrq, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Guarded state is installed, or a pending opposite request is coalesced away.
FlowPublish ==
    /\ fOwner = "normal"
    /\ fPhase = "hinted"
    /\ fWanted' = (fCapture)
    /\ fPending' = (fCapture # fSent /\ ~FlowDisabled(fCapture))
    /\ fBefore' = (IF fCapture # fSent /\ ~FlowDisabled(fCapture) /\ FLOWFENCE THEN Len(fQueue) ELSE 0)
    /\ fBarrier' = (2*(fNext - 1) + 1)
    /\ fHint' = (IF fCapture # fSent /\ ~FlowDisabled(fCapture) THEN fHint ELSE FALSE)
    /\ fSent' = (IF FlowDisabled(fCapture) THEN fCapture ELSE fSent)
    /\ fRequests' = (fRequests + 1)
    /\ fPhase' = ("published")
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls,  fCapture, fIrq, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Kick before releasing the console guard; a stopped publisher finishes after resume.
FlowKick ==
    /\ fOwner = "normal"
    /\ fPhase = "published"
    /\ fIrq' = (fIrq \/ (FLOWKICK /\ fPending))
    /\ fPhase' = ("idle")
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Transfer a ready control into a guarded local, before the physical FIFO store.
FlowTake ==
    /\ fOwner # "terminal"
    /\ fPhase = "idle"
    /\ fPending
    /\ fBefore = 0 \/ fPaused
    /\ fOwner = "stopped" \/ fIrq
    /\ fPending' = (FALSE)
    /\ fSent' = (fWanted)
    /\ fBefore' = (0)
    /\ fInFlight' = (fWanted)
    /\ fPhase' = ("inflight")
    /\ fActor' = (fOwner)
    /\ fOrderGood' = (fOrderGood /\ (fPaused \/ \A i \in DOMAIN fQueue : fQueue[i] > fBarrier))
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fCapture, fBarrier, fHint, fIrq, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Retire pending before clearing its hint; stopping here cannot lose the guarded local.
FlowClearHint ==
    /\ fOwner = fActor
    /\ fPhase = "inflight"
    /\ fHint' = (FALSE)
    /\ fPhase' = ("retired")
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fIrq, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* The same consumer completes its one FIFO store after a stop; no second consumer can duplicate it.
FlowStore ==
    /\ fOwner = fActor
    /\ fPhase = "retired"
    /\ fWire' = (Append(fWire, IF fInFlight THEN -1 ELSE -2))
    /\ fControls' = (Append(fControls, fInFlight))
    /\ fPhase' = ("idle")
    /\ UNCHANGED <<writerVars, fQueue, fNext, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fIrq, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* A TX/ordinary drain, or a force drain with a successfully acquired real guard under DDB.
FlowDrain ==
    /\ fOwner # "terminal"
    /\ fPhase = "idle"
    /\ fQueue # <<>>
    /\ fOwner = "stopped" \/ (~fPaused /\ fIrq)
    /\ ~(fPending /\ (fBefore = 0 \/ fPaused))
    /\ fQueue' = (Tail(fQueue))
    /\ fWire' = (Append(fWire, Head(fQueue)))
    /\ fBefore' = (IF fPending /\ fBefore > 0 THEN fBefore - 1 ELSE fBefore)
    /\ fOrderGood' = (fOrderGood /\ (~fPending \/ Head(fQueue) <= fBarrier))
    /\ UNCHANGED <<writerVars, fNext, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBarrier, fHint, fIrq, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Signal flush preserves kernel bytes and recomputes how many precede the pending control.
FlowFlush ==
    /\ fOwner = "normal"
    /\ fPhase = "idle"
    /\ \E i \in DOMAIN fQueue : fQueue[i] % 2 = 1
    /\ fQueue' = (SelectSeq(fQueue, LAMBDA byte : byte % 2 = 0))
    /\ fBefore' = (IF FLOWCOMPACT THEN Len(SelectSeq(SubSeq(fQueue, 1, fBefore), LAMBDA byte : byte % 2 = 0)) ELSE fBefore)
    /\ UNCHANGED <<writerVars, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBarrier, fHint, fIrq, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* The run-guarded policy publishes peer pause before acquiring the console guard.
FlowPauseState ==
    /\ fOwner = "normal"
    /\ fPauseStage = 0
    /\ fPaused' = (TRUE)
    /\ fPauseStage' = (1)
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fIrq, fPhase, fActor, fOwner, fStopSeen, fTerminal, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* A separate console critical section rechecks pending work before masking TXIM.
FlowPause ==
    /\ fOwner = "normal"
    /\ fPhase = "idle"
    /\ fPauseStage = 1
    /\ fPauseStage' = (2)
    /\ fIrq' = (FLOWPAUSE /\ fPending)
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Policy publishes peer START before the separate console drain/kick.
FlowResumeState ==
    /\ fOwner = "normal"
    /\ fPauseStage = 2
    /\ fPaused' = (FALSE)
    /\ fPauseStage' = (3)
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fIrq, fPhase, fActor, fOwner, fStopSeen, fTerminal, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* The existing resume drain/kick is a different console critical section.
FlowResume ==
    /\ fOwner = "normal"
    /\ fPhase = "idle"
    /\ fPauseStage = 3
    /\ fPauseStage' = (4)
    /\ fIrq' = (fIrq \/ fPending \/ fQueue # <<>> \/ fEcho \/ fWake)
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* An empty or paused TX service disables its source only when no control is pending.
FlowQuiesce ==
    /\ fOwner = "normal"
    /\ fPhase = "idle"
    /\ fIrq
    /\ ~fPending
    /\ ~fWake
    /\ fPaused \/ (fQueue = <<>> /\ ~fEcho)
    /\ fIrq' = (FALSE)
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* An unrelated console reader may be stopped holding the lock after publication.
FlowHold ==
    /\ fOwner = "normal"
    /\ fPhase = "idle"
    /\ ~fHoldSeen
    /\ fHoldSeen' = (TRUE)
    /\ fPhase' = ("hold")
    /\ fActor' = ("normal")
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fIrq, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* That reader releases without a new queue append or an implicit flow kick.
FlowReleaseHold ==
    /\ fOwner = "normal"
    /\ fPhase = "hold"
    /\ fPhase' = ("idle")
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fIrq, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Complete stop and TXIM disable; a retained guard makes DDB try-lock Busy.
FlowStop ==
    /\ fOwner = "normal"
    /\ ~fStopSeen
    /\ fOwner' = ("stopped")
    /\ fStopSeen' = (TRUE)
    /\ fIrq' = (FALSE)
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fPhase, fActor, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Rearm from the atomic hint only after restoring exact live ownership under complete stop.
FlowContinue ==
    /\ fOwner = "stopped"
    /\ (fPhase # "idle" /\ fActor = "normal") \/ (fPhase = "idle" /\ fQueue = <<>> /\ ~fPending /\ ~fEcho)
    /\ fOwner' = (IF fTerminal THEN "terminal" ELSE "normal")
    /\ fIrq' = (FLOWREARM /\ (fHint \/ (FLOWWORK /\ ((~fPaused /\ (fQueue # <<>> \/ fEcho)) \/ fWake))) /\ (~FLOWOWNERSAFE \/ ~fTerminal))
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fPhase, fActor, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* A non-returning owner makes terminal ownership sticky, including while DDB owns the console.
FlowTerminal ==
    /\ fOwner # "terminal"
    /\ ~fTerminal
    /\ fTerminal' = (TRUE)
    /\ fOwner' = (IF fOwner = "stopped" THEN "stopped" ELSE "terminal")
    /\ fIrq' = (FALSE)
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fPhase, fActor, fStopSeen, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>

\* Completed execution stutters; terminal ownership owes no ordinary flow progress.
FlowFinished ==
    /\ fOwner = "terminal" \/ (fRequests = 3 /\ fPhase = "idle" /\ ~fPending /\ fQueue = <<>> /\ fNext = 4)

    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fIrq, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho, fWake>>


\* One independent echo or owed-wake publication, with the ordinary producer kick.
FlowOfferAux ==
    /\ fOwner = "normal"
    /\ fPhase = "idle"
    /\ ~fAuxOffered
    /\ fAuxKind # "none"
    /\ fAuxOffered' = (TRUE)
    /\ fEcho' = (fAuxKind = "echo")
    /\ fWake' = (fAuxKind = "wake")
    /\ fIrq' = (fIrq \/ fAuxKind = "wake" \/ ~fPaused)
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind>>

\* Echo drains after ordinary queued data; a complete-stop force drain uses a real try-guard.
FlowDrainEcho ==
    /\ fOwner # "terminal"
    /\ fPhase = "idle"
    /\ fEcho
    /\ fQueue = <<>>
    /\ ~fPending
    /\ fOwner = "stopped" \/ (~fPaused /\ fIrq)
    /\ fEcho' = (FALSE)
    /\ fWire' = (Append(fWire, 8))
    /\ UNCHANGED <<writerVars, fQueue, fNext, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fIrq, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fWake>>

\* TX service retires owed wake; the run-lock wake itself remains in the writer/wake slice.
FlowWakeService ==
    /\ fOwner = "normal"
    /\ fPhase = "idle"
    /\ fIrq
    /\ fWake
    /\ fWake' = (FALSE)
    /\ UNCHANGED <<writerVars, fQueue, fNext, fWire, fControls, fRequests, fWanted, fSent, fCapture, fPending, fBefore, fBarrier, fHint, fIrq, fPhase, fActor, fOwner, fStopSeen, fTerminal, fPaused, fPauseStage, fHoldSeen, fInFlight, fOrderGood, fAuxKind, fAuxOffered, fEcho>>

FlowNext ==
    \/ FlowAppend
    \/ FlowBegin
    \/ FlowPublish
    \/ FlowKick
    \/ FlowTake
    \/ FlowClearHint
    \/ FlowStore
    \/ FlowDrain
    \/ FlowFlush
    \/ FlowPauseState
    \/ FlowPause
    \/ FlowResumeState
    \/ FlowResume
    \/ FlowQuiesce
    \/ FlowHold
    \/ FlowReleaseHold
    \/ FlowStop
    \/ FlowContinue
    \/ FlowTerminal
    \/ FlowOfferAux
    \/ FlowDrainEcho
    \/ FlowWakeService
    \/ FlowFinished

FlowFairness ==
    /\ WF_vars(FlowAppend)
    /\ WF_vars(FlowBegin)
    /\ WF_vars(FlowPublish)
    /\ WF_vars(FlowKick)
    /\ WF_vars(FlowTake)
    /\ WF_vars(FlowClearHint)
    /\ WF_vars(FlowStore)
    /\ WF_vars(FlowDrain)
    /\ WF_vars(FlowPauseState)
    /\ WF_vars(FlowPause)
    /\ WF_vars(FlowResumeState)
    /\ WF_vars(FlowResume)
    /\ WF_vars(FlowQuiesce)
    /\ WF_vars(FlowHold)
    /\ WF_vars(FlowReleaseHold)
    /\ WF_vars(FlowStop)
    /\ WF_vars(FlowContinue)
    /\ WF_vars(FlowOfferAux)
    /\ WF_vars(FlowDrainEcho)
    /\ WF_vars(FlowWakeService)

FlowTypeOK ==
    /\ Len(fQueue) <= 2
    /\ \A i \in DOMAIN fQueue : fQueue[i] \in 2..7
    /\ fNext \in 1..4
    /\ fRequests \in 0..3
    /\ fBefore \in 0..2
    /\ fBarrier \in 0..7
    /\ fPhase \in {"idle", "hinted", "published", "inflight", "retired", "hold"}
    /\ fOwner \in {"normal", "stopped", "terminal"}
    /\ fActor \in {"normal", "stopped"}
    /\ fPauseStage \in 0..4
    /\ fAuxKind \in {"none", "echo", "wake"}
    /\ ~(fEcho /\ fWake)

FlowFenceExact == fPending =>
    fBefore = Len(SelectSeq(fQueue, LAMBDA byte : byte <= fBarrier))
FlowHintCoversPending == fPending => fHint
FlowNoStranded ==
    (fOwner = "normal" /\ fPhase = "idle" /\ fPending) => fIrq
FlowNoOvertake == fOrderGood
FlowTerminalQuiet == fTerminal => ~fIrq
FlowNoDuplicate ==
    (FLOWSTOPDISABLED \/ FLOWSTARTDISABLED) \/
    \A i \in DOMAIN fControls :
        fControls[i] # (IF i = 1 THEN FALSE ELSE fControls[i-1])
FlowSafety == FlowTypeOK /\ FlowFenceExact /\ FlowHintCoversPending /\
              FlowNoStranded /\ FlowNoOvertake /\ FlowTerminalQuiet /\ FlowNoDuplicate
Safety == IF FLOW THEN FlowSafety ELSE ProgramOrder /\ NoLostWakeup

FlowLatest == <>(fOwner = "terminal" \/
    (fRequests = 3 /\ fPhase = "idle" /\ ~fPending /\ fSent = fWanted /\
     (FlowDisabled(fWanted) \/
      IF fControls = <<>> THEN ~fWanted ELSE fControls[Len(fControls)] = fWanted)))
FlowQuiesces == <>(fOwner = "terminal" \/
    (fRequests = 3 /\ fNext = 4 /\ fPhase = "idle" /\
     ~fPending /\ fQueue = <<>> /\ ~fEcho /\ ~fWake /\ ~fIrq))

Init == WriterInit /\ FlowIdleInit
Next == IF FLOW THEN FlowNext ELSE WriterNext
\* TLC follows each family directly so it reports individual action coverage.
\* Apalache uses Next above with the same constant-selected transition family.
Spec == Init /\ [][WriterNext]_vars /\ WriterFairness
FlowSpec == Init /\ [][FlowNext]_vars /\ FlowFairness

CInitFlowFixed == FLOW = TRUE /\ FlowDefaults /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE
CInitFlowNoKick == FLOW = TRUE /\ FLOWKICK = FALSE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = TRUE
CInitFlowNoFence == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = FALSE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = TRUE
CInitFlowNoCompact == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = FALSE /\ FLOWHINT = TRUE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = TRUE
CInitFlowLateHint == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = FALSE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = TRUE
CInitFlowNoRearm == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\ FLOWREARM = FALSE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = TRUE
CInitFlowBadOwner == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = FALSE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = TRUE
CInitFlowPauseOff == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = FALSE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = TRUE

CInitFlowStopDisabled == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = TRUE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = TRUE
CInitFlowStartDisabled == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = TRUE /\ FLOWWORK = TRUE
CInitFlowBothDisabled == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = TRUE /\ FLOWSTARTDISABLED = TRUE /\ FLOWWORK = TRUE

CInitFlowHintOnly == FLOW = TRUE /\ FLOWKICK = TRUE /\ FLOWFENCE = TRUE /\ FLOWCOMPACT = TRUE /\ FLOWHINT = TRUE /\ FLOWREARM = TRUE /\ FLOWOWNERSAFE = TRUE /\ FLOWPAUSE = TRUE /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE /\ FLOWSTOPDISABLED = FALSE /\ FLOWSTARTDISABLED = FALSE /\ FLOWWORK = FALSE

CInitFixed == FLOW = FALSE /\ FlowDefaults /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE
CInitRing == FLOW = FALSE /\ FlowDefaults /\ LOCKED = FALSE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE
CInitNoRecheck == FLOW = FALSE /\ FlowDefaults /\ LOCKED = TRUE /\ RECHECK = FALSE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE
CInitNested == FLOW = FALSE /\ FlowDefaults /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = TRUE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = FALSE
CInitPreemptible == FLOW = FALSE /\ FlowDefaults /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = TRUE /\ PREEMPTIBLE = TRUE
CInitNoPollWake == FLOW = FALSE /\ FlowDefaults /\ LOCKED = TRUE /\ RECHECK = TRUE /\ NESTED = FALSE /\ POLLWAKE = FALSE /\ PREEMPTIBLE = FALSE

=============================================================================
