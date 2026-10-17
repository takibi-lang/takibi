------------------------- MODULE WorldStopRetry -------------------------
(* GitHub issue #641: liveness of the Busy/Partial retry of a whole-machine
   stop, with every CPU a possible initiator.

   WorldStop.tla checks the safety of a Complete token against CPU startup
   and partial membership. This model is the retry slice of the same
   protocol: any CPU may need a Complete stop (an ASID rollover) and retries
   on Busy and Partial, any other CPU may be interrupted into the hold pen,
   or be inside an IRQ-masked section -- a finite one, a spin on the one
   modelled IRQ-masking lock, or (variant stuck) one that never ends.

   The bounded spin budget is modelled by when Timeout may fire. The kernel
   spins SCHEDULER_WORLD_STOP_SPINS rounds; the timing assumption this model
   states, and does not prove, is that every acknowledgement that CAN arrive
   arrives within that budget: Timeout (Partial) fires only while some
   target cannot acknowledge in time (LongMasked below). Variant shortbudget
   drops that assumption and must lose liveness.

   Three CPUs; no generations: an acknowledgement is a member of `acked`,
   which every publication and release empties, the abstraction of "the ack
   word equals the current request". WorldStop.tla checks the stale-ack
   window this abstraction leaves out. Bounded evidence, not a proof. *)
EXTENDS Naturals, FiniteSets
CONSTANTS
    \* @type: Bool;
    RETRY,           \* Busy/Partial retried; FALSE = fail-stopped (#632)
    \* @type: Bool;
    ANY_INITIATOR,   \* a stop begun on any CPU is acknowledged (#632's IAR)
    \* @type: Bool;
    OPEN_BACKOFF,    \* IRQs are open between attempts
    \* @type: Bool;
    LOCK_FREE_STOP,  \* no IRQ-masking lock is held across an attempt
    \* @type: Bool;
    LONG_ENDS,       \* a masked section longer than the budget still ends
    \* @type: Bool;
    BUDGET_COVERS    \* Timeout only while some target cannot ack in time
VARIABLES
    \* @type: Int -> Str;
    pc,
    \* @type: Int -> Str;
    ret,
    \* @type: Set(Int);
    wants,
    \* @type: Int;
    owner,
    \* @type: Str;
    phase,
    \* @type: Set(Int);
    acked,
    \* @type: Int;
    lock,
    \* @type: Int;
    longLeft,
    \* @type: Bool;
    failed

Cpus == 1..3
vars == <<pc, ret, wants, owner, phase, acked, lock, longLeft, failed>>

Init ==
    /\ pc = [c \in Cpus |-> "Run"]
    /\ ret = [c \in Cpus |-> "Run"]
    /\ wants = {}
    /\ owner = 0
    /\ phase = "Idle"
    /\ acked = {}
    /\ lock = 0
    /\ longLeft = 1
    /\ failed = FALSE

\* The hold accepts this request: world_stop_hold compares the published
\* owner with its own CPU only. The defect #632 met decoded the sender so
\* that only CPU 1's (core 0's) stop was recognised.
AckAccepts == ANY_INITIATOR \/ owner = 1

IrqOpen(c) == pc[c] = "Run" \/ (pc[c] = "Backoff" /\ OPEN_BACKOFF)

\* The SGI is pending at c. A pending SGI is taken at the first instruction
\* that runs with IRQs open, so while it is pending an IRQ-open CPU does
\* nothing but acknowledge (the other actions of an IRQ-open c require
\* ~Pending(c)).
Pending(c) ==
    /\ phase = "Waiting"
    /\ c # owner
    /\ c \notin acked
    /\ AckAccepts

\* Target t cannot acknowledge within the spin budget of initiator o.
LongMasked(t, o) ==
    \/ pc[t] = "Long"                       \* masked past the budget
    \/ pc[t] = "Dead"
    \/ (pc[t] = "Spin" /\ (lock = o \/ (lock # 0 /\ pc[lock] = "Pen")))
    \/ (pc[t] \in {"Try", "Backoff"} /\ ~OPEN_BACKOFF)
    \/ ~AckAccepts

TimeoutAllowed(o) ==
    \/ ~BUDGET_COVERS
    \/ \E t \in Cpus \ {o} : t \notin acked /\ LongMasked(t, o)

(* ---- a CPU that is not stopping the world ---- *)

\* An ordinary IRQ-masked section holding the modelled lock (mutex_acquire).
Enter(c) ==
    /\ pc[c] = "Run" /\ ~Pending(c)
    /\ lock = 0
    /\ pc' = [pc EXCEPT ![c] = "Masked"]
    /\ lock' = c
    /\ UNCHANGED <<ret, wants, owner, phase, acked, longLeft, failed>>

\* Mask, then spin on the lock another CPU holds.
EnterSpin(c) ==
    /\ pc[c] = "Run" /\ ~Pending(c)
    /\ lock # 0
    /\ pc' = [pc EXCEPT ![c] = "Spin"]
    /\ UNCHANGED <<ret, wants, owner, phase, acked, lock, longLeft, failed>>

Acquire(c) ==
    /\ pc[c] = "Spin"
    /\ lock = 0
    /\ pc' = [pc EXCEPT ![c] = "Masked"]
    /\ lock' = c
    /\ UNCHANGED <<ret, wants, owner, phase, acked, longLeft, failed>>

Exit(c) ==
    /\ pc[c] = "Masked"
    /\ pc' = [pc EXCEPT ![c] = "Run"]
    /\ lock' = 0
    /\ UNCHANGED <<ret, wants, owner, phase, acked, longLeft, failed>>

\* A masked section longer than the spin budget (a peer in DDB or the crash
\* console with IRQs masked, a fault loop at EL1). Finitely many: longLeft.
LongEnter(c) ==
    /\ pc[c] = "Run" /\ ~Pending(c)
    /\ longLeft > 0
    /\ pc' = [pc EXCEPT ![c] = "Long"]
    /\ longLeft' = longLeft - 1
    /\ UNCHANGED <<ret, wants, owner, phase, acked, lock, failed>>

LongExit(c) ==
    /\ LONG_ENDS
    /\ pc[c] = "Long"
    /\ pc' = [pc EXCEPT ![c] = "Run"]
    /\ UNCHANGED <<ret, wants, owner, phase, acked, lock, longLeft, failed>>

\* world_stop_interrupt_hold: ack the current request and spin in the pen.
Ack(c) ==
    /\ IrqOpen(c) /\ Pending(c)
    /\ pc' = [pc EXCEPT ![c] = "Pen"]
    /\ ret' = [ret EXCEPT ![c] = pc[c]]
    /\ acked' = acked \cup {c}
    /\ UNCHANGED <<wants, owner, phase, lock, longLeft, failed>>

\* The request this CPU acknowledged was released (or overtaken).
PenExit(c) ==
    /\ pc[c] = "Pen"
    /\ c \notin acked
    /\ pc' = [pc EXCEPT ![c] = ret[c]]
    /\ UNCHANGED <<ret, wants, owner, phase, acked, lock, longLeft, failed>>

(* ---- a CPU that needs a Complete stop (ASID rollover) ---- *)

\* RolloverNeeded, then world_stop_machine_begin masks IRQs (mutex_irq_save).
Need(c) ==
    /\ pc[c] = "Run" /\ ~Pending(c)
    /\ c \notin wants
    /\ pc' = [pc EXCEPT ![c] = "Try"]
    /\ wants' = wants \cup {c}
    /\ UNCHANGED <<ret, owner, phase, acked, lock, longLeft, failed>>

\* The same, while holding the IRQ-masking lock (variant holdlock).
NeedLocked(c) ==
    /\ ~LOCK_FREE_STOP
    /\ pc[c] = "Masked" /\ lock = c
    /\ c \notin wants
    /\ pc' = [pc EXCEPT ![c] = "Try"]
    /\ wants' = wants \cup {c}
    /\ UNCHANGED <<ret, owner, phase, acked, lock, longLeft, failed>>

\* Claim, publish the request, notify every other participant.
Claim(c) ==
    /\ pc[c] = "Try"
    /\ owner = 0
    /\ owner' = c
    /\ phase' = "Waiting"
    /\ acked' = {}
    /\ pc' = [pc EXCEPT ![c] = "Wait"]
    /\ UNCHANGED <<ret, wants, lock, longLeft, failed>>

\* Busy: restore IRQs, back off and retry; or fail-stop (#632's defect).
Busy(c) ==
    /\ pc[c] = "Try"
    /\ owner # 0
    /\ pc' = [pc EXCEPT ![c] = IF RETRY THEN "Backoff" ELSE "Dead"]
    /\ failed' = (failed \/ ~RETRY)
    /\ UNCHANGED <<ret, wants, owner, phase, acked, lock, longLeft>>

Complete(c) ==
    /\ pc[c] = "Wait" /\ owner = c /\ phase = "Waiting"
    /\ Cpus \ {c} \subseteq acked
    /\ phase' = "Complete"
    /\ UNCHANGED <<pc, ret, wants, owner, acked, lock, longLeft, failed>>

\* Partial: the spin budget ran out; release, restore IRQs, back off.
Timeout(c) ==
    /\ pc[c] = "Wait" /\ owner = c /\ phase = "Waiting"
    /\ TimeoutAllowed(c)
    /\ pc' = [pc EXCEPT ![c] = IF RETRY THEN "Backoff" ELSE "Dead"]
    /\ phase' = "Idle"
    /\ owner' = 0
    /\ acked' = {}
    /\ failed' = (failed \/ ~RETRY)
    /\ UNCHANGED <<ret, wants, lock, longLeft>>

\* Rollover under the Complete stop, then machine_stop_release. One rollover
\* makes the ASID generation current for every CPU, so it serves every CPU
\* that needed one: each re-runs process_image_prepare_activation after its
\* back-off and finds a current generation (Retry).
Finish(c) ==
    /\ pc[c] = "Wait" /\ owner = c /\ phase = "Complete"
    /\ pc' = [pc EXCEPT ![c] = IF lock = c THEN "Masked" ELSE "Run"]
    /\ phase' = "Idle"
    /\ owner' = 0
    /\ acked' = {}
    /\ wants' = {}
    /\ UNCHANGED <<ret, lock, longLeft, failed>>

\* After the back-off the activation is prepared again: a stop is begun only
\* while a rollover is still needed.
Retry(c) ==
    /\ pc[c] = "Backoff"
    /\ ~(OPEN_BACKOFF /\ Pending(c))
    /\ pc' = [pc EXCEPT ![c] = IF c \notin wants
                                   THEN (IF lock = c THEN "Masked" ELSE "Run")
                                   ELSE "Try"]
    /\ UNCHANGED <<ret, wants, owner, phase, acked, lock, longLeft, failed>>

Next ==
    \E c \in Cpus :
        \/ Enter(c) \/ EnterSpin(c) \/ Acquire(c) \/ Exit(c)
        \/ LongEnter(c) \/ LongExit(c) \/ Ack(c) \/ PenExit(c)
        \/ Need(c) \/ NeedLocked(c) \/ Claim(c) \/ Busy(c)
        \/ Complete(c) \/ Timeout(c) \/ Finish(c) \/ Retry(c)

(* Fairness, each justified in kernel/models/README.md: every step a CPU
   takes on its own without waiting for an outside event is weakly fair;
   lock acquisition is strongly fair (an assumption: the mutex spin is not
   FIFO). Entering a masked section and needing a stop are not fair. *)
Fair(c) ==
    /\ WF_vars(Ack(c)) /\ WF_vars(PenExit(c)) /\ WF_vars(Exit(c))
    /\ WF_vars(LongExit(c)) /\ SF_vars(Acquire(c))
    /\ WF_vars(Claim(c)) /\ WF_vars(Busy(c)) /\ WF_vars(Complete(c))
    /\ WF_vars(Timeout(c)) /\ WF_vars(Finish(c)) /\ WF_vars(Retry(c))
Spec == Init /\ [][Next]_vars /\ \A c \in Cpus : Fair(c)

States == {"Run", "Masked", "Spin", "Long", "Pen", "Try", "Wait",
           "Backoff", "Dead"}
TypeOK ==
    /\ pc \in [Cpus -> States] /\ ret \in [Cpus -> States]
    /\ wants \subseteq Cpus /\ owner \in 0..3 /\ lock \in 0..3
    /\ phase \in {"Idle", "Waiting", "Complete"}
    /\ acked \subseteq Cpus /\ longLeft \in 0..1 /\ failed \in BOOLEAN
\* A Complete token only while every other CPU is held in the pen.
StoppedWhileComplete ==
    phase = "Complete" => \A t \in Cpus \ {owner} : pc[t] = "Pen" /\ t \in acked
\* Only an acknowledging CPU of the live request is counted as stopped.
AckedInPen == \A t \in acked : pc[t] = "Pen" /\ phase # "Idle" /\ t # owner
NoFailStop == ~failed
Safety == TypeOK /\ StoppedWhileComplete /\ AckedInPen /\ NoFailStop

\* Every CPU that needs a Complete stop eventually gets one.
RetrySucceeds == \A c \in Cpus : (c \in wants) ~> (c \notin wants)
\* Every stopped CPU is resumed: release lets exactly the pen go.
PenResumes == \A c \in Cpus : (pc[c] = "Pen") ~> (pc[c] # "Pen")

\* @type: (Bool, Bool, Bool, Bool, Bool, Bool) => Bool;
Variant(r, a, o, l, e, b) ==
    /\ RETRY = r /\ ANY_INITIATOR = a /\ OPEN_BACKOFF = o
    /\ LOCK_FREE_STOP = l /\ LONG_ENDS = e /\ BUDGET_COVERS = b
CInitFixed == Variant(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE)
CInitFailStop == Variant(FALSE, TRUE, TRUE, TRUE, TRUE, TRUE)
CInitCore0Ack == Variant(TRUE, FALSE, TRUE, TRUE, TRUE, TRUE)
CInitMaskedBackoff == Variant(TRUE, TRUE, FALSE, TRUE, TRUE, TRUE)
CInitHoldLock == Variant(TRUE, TRUE, TRUE, FALSE, TRUE, TRUE)
CInitStuck == Variant(TRUE, TRUE, TRUE, TRUE, FALSE, TRUE)
CInitShortBudget == Variant(TRUE, TRUE, TRUE, TRUE, TRUE, FALSE)
=============================================================================
