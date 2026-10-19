---------------------------- MODULE LogRingTrace ----------------------------
(***************************************************************************)
(* Trace validation of LogRing.tla (GitHub issue #656), in the shape of    *)
(* StackOwnershipTrace.tla (#606).                                         *)
(*                                                                         *)
(* A window of the kernel log ring is recorded per stream: one stream per *)
(* writing CPU, in that CPU's program order, and one for the reader. Each *)
(* event is one serialization point of LogRing.tla: the head compare-swap *)
(* (Reserve), a slot compare-swap that claimed, refused, committed or     *)
(* found its slot taken (Claim, Refuse, Commit, CommitLost), the end of a *)
(* slot's text stores (Write), and each of the reader's word loads and    *)
(* copies (ReadHead .. ContCheck), carrying the slot word it observed.     *)
(*                                                                         *)
(* No CPU-global order is recorded: a shared counter would be one more     *)
(* contended atomic inside the protocol, and its order need not be the     *)
(* compare-swaps' order. TLC instead looks for an interleaving of the     *)
(* streams that LogRing.tla allows, every event as the model action it    *)
(* names, with the model's enabling condition, and every observed word    *)
(* equal to the model's word at that point. The model is sequentially     *)
(* consistent; the AArch64 orderings that justify that are the litmus     *)
(* tests (kernel/models/litmus/LogRing*.litmus), not this check.          *)
(*                                                                         *)
(* Each event also carries the system counter read before and after its   *)
(* atomic access (t0, t1). The counter is one per system, so an event     *)
(* whose interval ends before another's begins happened first: InOrder   *)
(* keeps TLC to the interleavings that agree, which is what makes a reader *)
(* stream next to the writers checkable (#656, maintainer option A).      *)
(*                                                                         *)
(* scripts/validate_log_ring_trace.py only parses: it writes the         *)
(* window as the module LogRingTraceData, sequences shifted by a         *)
(* multiple of the slot count (which keeps every slot index and order),   *)
(* and the state at the window's opening, taken from the events           *)
(* themselves (see the validator). No enabling condition or effect is     *)
(* written anywhere but LogRing.tla.                                       *)
(*                                                                         *)
(* The trace is a behaviour of the model iff a state with every stream    *)
(* consumed is reachable with the invariants intact: TLC reports exactly  *)
(* that as "Invariant TraceUnfinished is violated". If no interleaving    *)
(* matches, TLC completes with no error.                                   *)
(*                                                                         *)
(* What a PASS claims is narrow: every ring transition the kernel made in *)
(* this window is one LogRing.tla has, in some order the model allows. It *)
(* does not claim the model is right, nor anything about paths the window *)
(* did not run.                                                            *)
(***************************************************************************)

EXTENDS Integers, Sequences, LogRingTraceData

CONSTANTS
    \* LogRing.tla's defect constants, TRUE/FALSE as in LogRing_fixed.cfg
    \* unless a control sets one to show which guard refused a step.
    TRUST_RESERVED, CHECK_PREV, CONT_SEQ, REPORT_REFUSAL,
    \* An action left out, or "none": the negative control that a path the
    \* model lacked fails a passing run.
    WITHOUT,
    \* 0, or an event count to stop at, for the refusal report.
    STOP_AT

VARIABLES
    head, word, text, wpc, wseq, wk, wi, rpc, rnext, rspan, copyH, copyC,
    returned, reported, tornReturned, needless,
    pos,    \* per stream: events consumed
    l,      \* events consumed in all
    act     \* the model action the last step was, for the report

ring == <<head, word, text, wpc, wseq, wk, wi, rpc, rnext, rspan, copyH,
          copyC, returned, reported, tornReturned, needless>>

Ring == INSTANCE LogRing WITH
    NW <- TraceNW, N <- TraceN, SEQ_IN_WORD <- TRUE, PREV_EXACT <- FALSE,
    MAXSEQ <- TraceMaxSeq

Streams == DOMAIN Trace

Init ==
    /\ head = InitHead
    /\ word = InitWord
    /\ text = InitText
    /\ wpc = InitWpc
    /\ wseq = InitWseq
    /\ wk = InitWk
    /\ wi = InitWi
    /\ rpc = "idle"
    /\ rnext = InitRnext
    /\ rspan = 0
    /\ copyH = -1
    /\ copyC = -1
    \* Sequences before the reader's first are outside the window.
    /\ returned = {s \in 0 .. InitRnext : s < InitRnext}
    /\ reported = {}
    /\ tornReturned = FALSE
    /\ needless = FALSE
    /\ pos = [s \in Streams |-> 0]
    /\ l = 0
    /\ act = "snapshot"

----------------------------------------------------------------------------

\* @type: (Str) => Bool;
Allowed(name) == WITHOUT # name

\* Writer w's record is the one the event names, at the slot it names.
At(w, e) == wseq[w] = e.first /\ wk[w] = e.k /\ wi[w] = e.i

\* A writer stream's event, as the model action of that name.
WriterStep(w, e) ==
    \/ e.kind = "reserve" /\ Allowed("Reserve") /\ act' = "Reserve"
       /\ head = e.first /\ Ring!Reserve(w) /\ wk'[w] = e.k
    \/ e.kind = "claim" /\ Allowed("Claim") /\ act' = "Claim"
       /\ At(w, e) /\ word[e.seq % TraceN] = e.w /\ Ring!Claim(w)
    \/ e.kind = "refuse" /\ Allowed("Refuse") /\ act' = "Refuse"
       /\ At(w, e) /\ word[e.seq % TraceN] = e.w /\ Ring!Refuse(w)
    \/ e.kind = "write" /\ Allowed("Write") /\ act' = "Write"
       /\ At(w, e) /\ Ring!Write(w)
    \/ e.kind = "commit" /\ Allowed("Commit") /\ act' = "Commit"
       /\ At(w, e) /\ Ring!Commit(w)
    \/ e.kind = "commitlost" /\ Allowed("CommitLost") /\ act' = "CommitLost"
       /\ At(w, e) /\ word[e.seq % TraceN] = e.w /\ Ring!CommitLost(w)

\* What the kernel's reader did with the sequence must be what the model's
\* did: copied on, counted it lost, or skipped it uncounted.
Lost(s) == s \in reported'
Uncounted == reported' = reported

\* The reader stream's event, as the model action of that name.
ReaderStep(e) ==
    \/ e.kind = "head" /\ Allowed("ReadHead") /\ act' = "ReadHead"
       /\ rnext = e.seq /\ word[e.seq % TraceN] = e.w /\ Ring!ReadHead
       /\ \/ e.out = "copy" /\ rpc' = "headcopy"
          \/ e.out = "lost" /\ rpc' = "idle" /\ Lost(e.seq)
          \/ e.out = "skip" /\ rpc' = "idle" /\ Uncounted
    \/ e.kind = "copy" /\ Allowed("HeadCopy") /\ act' = "HeadCopy"
       /\ rnext = e.seq /\ Ring!HeadCopy
    \/ e.kind = "check" /\ Allowed("HeadCheck") /\ act' = "HeadCheck"
       /\ rnext = e.seq /\ word[e.seq % TraceN] = e.w /\ Ring!HeadCheck
       /\ \/ e.out = "kept" /\ e.seq \in returned'
          \/ e.out = "lost" /\ rpc' = "idle" /\ e.seq \notin returned'
             /\ Lost(e.seq)
          \/ e.out = "cont" /\ rpc' = "contcopy"
    \/ e.kind = "ccopy" /\ Allowed("ContCopy") /\ act' = "ContCopy"
       /\ rnext + 1 = e.seq /\ word[e.seq % TraceN] = e.w /\ Ring!ContCopy
       /\ \/ e.out = "copy" /\ rpc' = "contcheck"
          \/ e.out = "lost" /\ rpc' = "idle" /\ Lost(e.seq)
    \/ e.kind = "ccheck" /\ Allowed("ContCheck") /\ act' = "ContCheck"
       /\ rnext + 1 = e.seq /\ word[e.seq % TraceN] = e.w /\ Ring!ContCheck
       /\ \/ e.out = "kept" /\ e.seq \in returned'
          \/ e.out = "lost" /\ e.seq \notin returned' /\ Lost(e.seq)

\* No other stream's next event ended before e began. A stream's stamps only
\* grow, so its next event is the only one that could have.
InOrder(s, e) ==
    \A o \in Streams \ {s} :
        pos[o] < Len(Trace[o]) => ~(Trace[o][pos[o] + 1].t1 + TraceMargin < e.t0)

\* Stream 0 is the reader; stream c + 1 is CPU c, LogRing's writer c + 1.
Next ==
    \E s \in Streams :
        /\ pos[s] < Len(Trace[s])
        /\ InOrder(s, Trace[s][pos[s] + 1])
        /\ pos' = [pos EXCEPT ![s] = pos[s] + 1]
        /\ l' = l + 1
        /\ LET e == Trace[s][pos[s] + 1]
           IN  IF s = 0 THEN ReaderStep(e) ELSE WriterStep(s, e)

Spec == Init /\ [][Next]_<<ring, pos, l, act>>

----------------------------------------------------------------------------
(* LogRing.tla's invariants, checked after every event. *)

NoTornRead == Ring!NoTornRead
NoSilentLoss == Ring!NoSilentLoss
NoDoubleOwner == Ring!NoDoubleOwner
NoNeedlessRefusal == Ring!NoNeedlessRefusal

Invariants == NoTornRead /\ NoSilentLoss /\ NoDoubleOwner /\ NoNeedlessRefusal

NotStopped == STOP_AT = 0 \/ l # STOP_AT

\* Violated exactly when every stream has been matched: the PASS.
TraceUnfinished ==
    ~((\A s \in Streams : pos[s] = Len(Trace[s])) /\ Invariants)

=============================================================================
