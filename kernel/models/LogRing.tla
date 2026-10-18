----------------------------- MODULE LogRing -----------------------------
EXTENDS Integers, FiniteSets

(***************************************************************************)
(* The lockless multi-writer kernel log ring (GitHub issue #613, option B  *)
(* with multi-slot records; docs/LOG_RING_DESIGN.md). Written before any  *)
(* ring code exists, to check the design.                                  *)
(*                                                                         *)
(* N fixed slots. Sequence s lives in slot s % N. Each slot has one state *)
(* word (seq, state, span): state is Free (never used), Reserved,          *)
(* Committed or Discarded; span is the record's slot count in its first   *)
(* slot and 0 -- the continuation mark -- in the others.                   *)
(*                                                                         *)
(* A writer reserves a record of k <= K slots with ONE CAS on `head`       *)
(* (h -> h + k), then claims each slot h+i with a CAS from the previous   *)
(* occupant (h+i-N, Committed or Discarded) -- or Free, the first time    *)
(* round -- to (h+i, Reserved). If the previous occupant is not finished  *)
(* (a stalled writer still holds it Reserved) or was already taken, the   *)
(* writer does not wait: the claim is Refused, every sequence of the      *)
(* record is reported lost, the slots it already claimed are Discarded,   *)
(* and it holds no token. Otherwise it writes the text and commits each   *)
(* slot by a release CAS (seq, Reserved) -> (seq, Committed),              *)
(* continuations first and the first slot last.                            *)
(*                                                                         *)
(* One reader takes no lock. For the next sequence it acquire-loads the   *)
(* first slot's word, requires (rnext, Committed, span >= 1), copies the  *)
(* text, and re-loads the word; for a two-slot record it then does the    *)
(* same on the continuation, requiring (rnext+1, Committed, 0). Anything  *)
(* else is in flight, discarded (reported by the writer that refused) or  *)
(* overwritten, and the reader reports the sequence lost and moves on.    *)
(* Overwrite is oldest-first by construction: a claim of s replaces s-N.  *)
(*                                                                         *)
(* One action per atomic access, since there is no lock. Text is one      *)
(* value per slot: the sequence whose writer stored it; a copy holding    *)
(* any other value is torn. The model is sequentially consistent; the     *)
(* AArch64 orderings that make it so are the litmus tests under           *)
(* kernel/models/litmus/ (LogRing*.litmus).                                *)
(*                                                                         *)
(* Bound: NW writers, N slots, K = 2, sequences below MAXSEQ = 6.          *)
(***************************************************************************)

CONSTANTS
    \* @type: Int;
    NW,              \* writers
    \* @type: Int;
    N,               \* slots
    \* @type: Bool;
    SEQ_IN_WORD,     \* FALSE: the ABA control, a state word without seq
    \* @type: Bool;
    TRUST_RESERVED,  \* TRUE: the reader accepts a Reserved slot
    \* @type: Bool;
    CHECK_PREV,      \* FALSE: a claim ignores the previous occupant
    \* @type: Bool;
    CONT_SEQ,        \* FALSE: the reader accepts any continuation mark
    \* @type: Bool;
    REPORT_REFUSAL   \* FALSE: a refused writer discards without reporting

K == 2
MAXSEQ == 6

Writers == 1 .. NW
Slots == 0 .. N - 1
Seqs == 0 .. MAXSEQ - 1

\* Apalache wants constant ranges, so variable ones are filtered from these.
\* The sequences a .. a + n - 1:
Run(a, n) == {s \in 0 .. MAXSEQ + 1 : a <= s /\ s < a + n}
\* The slot indexes 0 .. n - 1 of a record:
Idx(n) == {j \in 0 .. K - 1 : j < n}

VARIABLES
    \* @type: Int;
    head,          \* next sequence to reserve
    \* @type: Int -> {seq: Int, st: Str, span: Int};
    word,          \* per slot: its state word
    \* @type: Int -> Int;
    text,          \* per slot: the sequence whose writer stored the text (-1 none)
    \* @type: Int -> Str;
    wpc,           \* per writer: "idle" | "claim" | "write" | "commit"
    \* @type: Int -> Int;
    wseq,          \* per writer: first sequence of its record
    \* @type: Int -> Int;
    wk,            \* per writer: slots in its record
    \* @type: Int -> Int;
    wi,            \* per writer: slot index it works on next
    \* @type: Str;
    rpc,           \* "idle" | "headcopy" | "headcheck" | "contcopy" | "contcheck"
    \* @type: Int;
    rnext,         \* next sequence the reader accounts for
    \* @type: Int;
    rspan,         \* span read from the first slot
    \* @type: Int;
    copyH,         \* copied text of the first slot
    \* @type: Int;
    copyC,         \* copied text of the continuation
    \* @type: Set(Int);
    returned,      \* sequences the reader returned
    \* @type: Set(Int);
    reported,      \* sequences reported lost (by a refused writer or the reader)
    \* @type: Bool;
    tornReturned   \* was a copy mixing records ever returned

vars == <<head, word, text, wpc, wseq, wk, wi, rpc, rnext, rspan, copyH,
          copyC, returned, reported, tornReturned>>
wvars == <<wpc, wseq, wk, wi>>
rvars == <<rpc, rnext, rspan, copyH, copyC, returned>>

Init ==
    /\ head = 0
    /\ word = [s \in Slots |-> [seq |-> -1, st |-> "Free", span |-> 0]]
    /\ text = [s \in Slots |-> -1]
    /\ wpc = [w \in Writers |-> "idle"]
    /\ wseq = [w \in Writers |-> 0]
    /\ wk = [w \in Writers |-> 0]
    /\ wi = [w \in Writers |-> 0]
    /\ rpc = "idle"
    /\ rnext = 0
    /\ rspan = 0
    /\ copyH = -1
    /\ copyC = -1
    /\ returned = {}
    /\ reported = {}
    /\ tornReturned = FALSE

\* Does word w carry sequence s? Without seq in the word (the ABA control)
\* every comparison of the sequence passes.
\* @type: ({seq: Int, st: Str, span: Int}, Int) => Bool;
SeqIs(w, s) == ~SEQ_IN_WORD \/ w.seq = s

----------------------------------------------------------------------------
(* Writers *)

\* kernel_log_reserve, first CAS: head h -> h + k claims sequences h..h+k-1.
Reserve(w) ==
    /\ wpc[w] = "idle"
    /\ \E k \in 1 .. K :
          /\ head + k <= MAXSEQ
          /\ head' = head + k
          /\ wseq' = [wseq EXCEPT ![w] = head]
          /\ wk' = [wk EXCEPT ![w] = k]
    /\ wi' = [wi EXCEPT ![w] = 0]
    /\ wpc' = [wpc EXCEPT ![w] = "claim"]
    /\ UNCHANGED <<word, text, rvars, reported, tornReturned>>

\* The previous occupant of the slot for sequence s may be replaced.
\* @type: ({seq: Int, st: Str, span: Int}, Int) => Bool;
PrevDone(cur, s) ==
    \/ ~CHECK_PREV
    \/ (cur.st \in {"Committed", "Discarded"} /\ SeqIs(cur, s - N))
    \/ (cur.st = "Free" /\ s < N)

\* kernel_log_reserve, per slot: CAS (s-N, Committed|Discarded) -> (s, Reserved).
Claim(w) ==
    LET s == wseq[w] + wi[w]
        sl == s % N
    IN  /\ wpc[w] = "claim"
        /\ PrevDone(word[sl], s)
        /\ word' = [word EXCEPT ![sl] =
                      [seq |-> s, st |-> "Reserved",
                       span |-> IF wi[w] = 0 THEN wk[w] ELSE 0]]
        /\ IF wi[w] + 1 = wk[w]
              THEN /\ wpc' = [wpc EXCEPT ![w] = "write"]
                   /\ wi' = [wi EXCEPT ![w] = 0]
              ELSE /\ wpc' = [wpc EXCEPT ![w] = "claim"]
                   /\ wi' = [wi EXCEPT ![w] = wi[w] + 1]
        /\ UNCHANGED <<head, text, wseq, wk, rvars, reported, tornReturned>>

\* The same CAS failing: the record is Refused. Its sequences are reported
\* lost, the slots already claimed (owned by this writer alone) Discarded,
\* and no token is returned.
Refuse(w) ==
    LET s == wseq[w] + wi[w]
        claimed == {(wseq[w] + j) % N : j \in Idx(wi[w])}
    IN  /\ wpc[w] = "claim"
        /\ ~PrevDone(word[s % N], s)
        /\ word' = [sl \in Slots |->
                      IF sl \in claimed
                        THEN [word[sl] EXCEPT !.st = "Discarded"]
                        ELSE word[sl]]
        /\ reported' = IF REPORT_REFUSAL
                         THEN reported \cup Run(wseq[w], wk[w])
                         ELSE reported
        /\ wpc' = [wpc EXCEPT ![w] = "idle"]
        /\ UNCHANGED <<head, text, wseq, wk, wi, rvars, tornReturned>>

\* Text into one slot through the token (release word stores).
Write(w) ==
    LET s == wseq[w] + wi[w]
    IN  /\ wpc[w] = "write"
        /\ text' = [text EXCEPT ![s % N] = s]
        /\ IF wi[w] + 1 = wk[w]
              THEN /\ wpc' = [wpc EXCEPT ![w] = "commit"]
                   /\ wi' = [wi EXCEPT ![w] = wk[w] - 1]
              ELSE /\ wpc' = [wpc EXCEPT ![w] = "write"]
                   /\ wi' = [wi EXCEPT ![w] = wi[w] + 1]
        /\ UNCHANGED <<head, word, wseq, wk, rvars, reported, tornReturned>>

\* kernel_log_commit: release CAS (s, Reserved) -> (s, Committed), the
\* continuation first, the first slot last.
Commit(w) ==
    LET s == wseq[w] + wi[w]
        sl == s % N
    IN  /\ wpc[w] = "commit"
        /\ word[sl].st = "Reserved" /\ SeqIs(word[sl], s)
        /\ word' = [word EXCEPT ![sl].st = "Committed"]
        /\ IF wi[w] = 0
              THEN /\ wpc' = [wpc EXCEPT ![w] = "idle"]
                   /\ wi' = wi
              ELSE /\ wpc' = [wpc EXCEPT ![w] = "commit"]
                   /\ wi' = [wi EXCEPT ![w] = wi[w] - 1]
        /\ UNCHANGED <<head, text, wseq, wk, rvars, reported, tornReturned>>

\* The commit CAS failing: someone took the slot. Only an unfixed variant
\* gets here; the record is gone, and the reader reports its sequence.
CommitLost(w) ==
    LET s == wseq[w] + wi[w]
        sl == s % N
    IN  /\ wpc[w] = "commit"
        /\ ~(word[sl].st = "Reserved" /\ SeqIs(word[sl], s))
        /\ wpc' = [wpc EXCEPT ![w] = "idle"]
        /\ UNCHANGED <<head, word, text, wseq, wk, wi, rvars, reported, tornReturned>>

----------------------------------------------------------------------------
(* The reader *)

\* A first slot the reader may copy as sequence r.
\* @type: ({seq: Int, st: Str, span: Int}, Int) => Bool;
HeadOk(w, r) ==
    /\ SeqIs(w, r)
    /\ w.span >= 1
    /\ (w.st = "Committed" \/ (TRUST_RESERVED /\ w.st = "Reserved"))

\* A continuation the reader may copy as sequence r.
\* @type: ({seq: Int, st: Str, span: Int}, Int) => Bool;
ContOk(w, r) ==
    /\ (~CONT_SEQ \/ SeqIs(w, r))
    /\ w.span = 0
    /\ (w.st = "Committed" \/ (TRUST_RESERVED /\ w.st = "Reserved"))

Skip(r, n, report) ==
    /\ rnext' = r + n
    /\ reported' = IF report THEN reported \cup Run(r, n) ELSE reported
    /\ rpc' = "idle"

\* Acquire-load the first slot's word of rnext.
ReadHead ==
    LET w == word[rnext % N]
    IN  /\ rpc = "idle"
        /\ rnext < head
        /\ IF HeadOk(w, rnext) /\ rnext + w.span <= head
              THEN /\ rspan' = w.span
                   /\ rpc' = "headcopy"
                   /\ UNCHANGED <<rnext, reported>>
              ELSE /\ IF w.st = "Discarded" /\ SeqIs(w, rnext)
                        THEN Skip(rnext, 1, FALSE)   \* the refusing writer reported it
                        ELSE Skip(rnext, 1, TRUE)    \* in flight, overwritten, or a stray continuation
                   /\ UNCHANGED rspan
        /\ UNCHANGED <<head, word, text, wvars, copyH, copyC, returned, tornReturned>>

HeadCopy ==
    /\ rpc = "headcopy"
    /\ copyH' = text[rnext % N]
    /\ rpc' = "headcheck"
    /\ UNCHANGED <<head, word, text, wvars, rnext, rspan, copyC, returned, reported, tornReturned>>

\* Re-load the first slot's word.
HeadCheck ==
    /\ rpc = "headcheck"
    /\ IF ~HeadOk(word[rnext % N], rnext)
          THEN /\ Skip(rnext, rspan, TRUE)
               /\ UNCHANGED <<returned, tornReturned>>
          ELSE IF rspan = 1
          THEN /\ returned' = returned \cup {rnext}
               /\ tornReturned' = (tornReturned \/ copyH # rnext)
               /\ Skip(rnext, 1, FALSE)
          ELSE /\ rpc' = "contcopy"
               /\ UNCHANGED <<rnext, reported, returned, tornReturned>>
    /\ UNCHANGED <<head, word, text, wvars, rspan, copyH, copyC>>

\* Acquire-load the continuation's word and copy its text.
ContCopy ==
    /\ rpc = "contcopy"
    /\ IF ContOk(word[(rnext + 1) % N], rnext + 1)
          THEN /\ copyC' = text[(rnext + 1) % N]
               /\ rpc' = "contcheck"
               /\ UNCHANGED <<rnext, reported>>
          ELSE /\ Skip(rnext, 2, TRUE)
               /\ UNCHANGED copyC
    /\ UNCHANGED <<head, word, text, wvars, rspan, copyH, returned, tornReturned>>

\* Re-load the continuation's word.
ContCheck ==
    /\ rpc = "contcheck"
    /\ IF ContOk(word[(rnext + 1) % N], rnext + 1)
          THEN /\ returned' = returned \cup {rnext, rnext + 1}
               /\ tornReturned' = (tornReturned \/ copyH # rnext \/ copyC # rnext + 1)
               /\ Skip(rnext, 2, FALSE)
          ELSE /\ Skip(rnext, 2, TRUE)
               /\ UNCHANGED <<returned, tornReturned>>
    /\ UNCHANGED <<head, word, text, wvars, rspan, copyH, copyC>>

Done ==
    /\ head = MAXSEQ
    /\ \A w \in Writers : wpc[w] = "idle"
    /\ rpc = "idle"
    /\ rnext >= head
    /\ UNCHANGED vars

Next ==
    \/ \E w \in Writers :
          \/ Reserve(w) \/ Claim(w) \/ Refuse(w) \/ Write(w)
          \/ Commit(w) \/ CommitLost(w)
    \/ ReadHead \/ HeadCopy \/ HeadCheck \/ ContCopy \/ ContCheck
    \/ Done

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ head \in 0 .. MAXSEQ
    /\ rnext \in 0 .. MAXSEQ + 1
    /\ \A w \in Writers : wpc[w] \in {"idle", "claim", "write", "commit"}
    /\ rpc \in {"idle", "headcopy", "headcheck", "contcopy", "contcheck"}
    /\ returned \subseteq Seqs
    /\ reported \subseteq 0 .. MAXSEQ

\* No copy the reader returns holds text of another record.
NoTornRead == ~tornReturned

\* Every sequence the reader has gone past was returned or reported lost.
NoSilentLoss == \A s \in Run(0, rnext) : s \in returned \cup reported

\* The slots writer w holds a token for: claimed and not yet committed.
Held(w) ==
    IF wpc[w] = "claim" THEN {(wseq[w] + j) % N : j \in Idx(wi[w])}
    ELSE IF wpc[w] = "write" THEN {(wseq[w] + j) % N : j \in Idx(wk[w])}
    ELSE IF wpc[w] = "commit" THEN {(wseq[w] + j) % N : j \in Idx(wi[w] + 1)}
    ELSE {}

\* No slot is held by two writers at once.
NoDoubleOwner ==
    \A v, w \in Writers : v # w => Held(v) \cap Held(w) = {}

Safety == TypeOK /\ NoTornRead /\ NoSilentLoss /\ NoDoubleOwner

----------------------------------------------------------------------------
(* Constant initializers for Apalache. *)

CInitBase(nw, n, seq, trust, prev, cont, report) ==
    /\ NW = nw /\ N = n /\ SEQ_IN_WORD = seq /\ TRUST_RESERVED = trust
    /\ CHECK_PREV = prev /\ CONT_SEQ = cont /\ REPORT_REFUSAL = report

CInitFixed == CInitBase(3, 3, TRUE, FALSE, TRUE, TRUE, TRUE)
CInitFixed4 == CInitBase(2, 4, TRUE, FALSE, TRUE, TRUE, TRUE)
CInitAba == CInitBase(2, 3, FALSE, FALSE, TRUE, TRUE, TRUE)
CInitTrustReserved == CInitBase(2, 3, TRUE, TRUE, TRUE, TRUE, TRUE)
CInitNoPrev == CInitBase(2, 3, TRUE, FALSE, FALSE, TRUE, TRUE)
CInitContNoSeq == CInitBase(2, 3, TRUE, FALSE, TRUE, FALSE, TRUE)
CInitSilentRefuse == CInitBase(2, 3, TRUE, FALSE, TRUE, TRUE, FALSE)

=============================================================================
