-------------------------- MODULE RecordLifetime --------------------------
(***************************************************************************)
(* A process record read by one CPU while another CPU reaps it (GitHub     *)
(* issue #482).                                                            *)
(*                                                                         *)
(* A reader -- a scheduler walk, a timer-side wake -- asks the pool whether *)
(* a record is live, gets a pointer, lets the pool's view go, and THEN     *)
(* reads through the pointer. It holds the process-run lock from the probe *)
(* to the end of the read. A reaper on another CPU hands the record back   *)
(* to the pool: first a teardown of what the process alone owned, then the *)
(* removal of the record itself.                                           *)
(*                                                                         *)
(* REMOVE_UNDER_LOCK = FALSE is the kernel before #482: the removal ran    *)
(* outside the run lock, so it could land between the reader's probe and  *)
(* its read. TLC must find ReadsOnlyLiveRecords violated.                  *)
(* REMOVE_UNDER_LOCK = TRUE is the fix: scheduled_process_slot_remove     *)
(* requires the run lock's guard.                                          *)
(*                                                                         *)
(* READER_HOLDS_LOCK = FALSE breaks the assumption the fix rests on, which *)
(* no type checks: that a reader of another process's record holds the    *)
(* run lock from probe to read. With the fix in place and this assumption *)
(* broken, TLC must find the violation again -- the fix alone is not      *)
(* enough, and this variant is what says so.                               *)
(*                                                                         *)
(* One action per critical section, as in every model here.               *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    REMOVE_UNDER_LOCK,
    \* @type: Bool;
    READER_HOLDS_LOCK

VARIABLES
    \* @type: Str;
    record,     \* "Live" | "Exited" | "Freed": the record in the pool
    \* @type: Str;
    lockHolder, \* who holds the process-run lock across actions: "reader" | "none"
    \* @type: Str;
    reader,     \* "idle" | "probed" (holds a pointer) | "done"
    \* @type: Str;
    reaper,     \* "waiting" | "tornDown" | "done"
    \* @type: Bool;
    readFreed   \* did the reader ever read through a pointer to a freed record

vars == <<record, lockHolder, reader, reaper, readFreed>>

Init ==
    /\ record = "Live"
    /\ lockHolder = "none"
    /\ reader = "idle"
    /\ reaper = "waiting"
    /\ readFreed = FALSE

----------------------------------------------------------------------------
(* The process exits. From here a reaper may take it. *)

Exit ==
    /\ record = "Live"
    /\ record' = "Exited"
    /\ UNCHANGED <<lockHolder, reader, reaper, readFreed>>

(* The reader: take the lock (if it follows the rule), probe, read, release. *)

ReaderProbe ==
    /\ reader = "idle"
    /\ record # "Freed"          \* the pool answers Live for a slot it holds
    /\ IF READER_HOLDS_LOCK
         THEN /\ lockHolder = "none"
              /\ lockHolder' = "reader"
         ELSE UNCHANGED lockHolder
    /\ reader' = "probed"
    /\ UNCHANGED <<record, reaper, readFreed>>

\* The pool answers NoPayload for a slot it already gave back: the reader
\* reads nothing and is done.
ReaderMiss ==
    /\ reader = "idle"
    /\ record = "Freed"
    /\ reader' = "done"
    /\ UNCHANGED <<record, lockHolder, reaper, readFreed>>

ReaderRead ==
    /\ reader = "probed"
    /\ readFreed' = (readFreed \/ record = "Freed")
    /\ lockHolder' = IF lockHolder = "reader" THEN "none" ELSE lockHolder
    /\ reader' = "done"
    /\ UNCHANGED <<record, reaper>>

(* The reaper: the teardown needs no lock; the removal does, when fixed. *)

ReaperTeardown ==
    /\ reaper = "waiting"
    /\ record = "Exited"
    /\ reaper' = "tornDown"
    /\ UNCHANGED <<record, lockHolder, reader, readFreed>>

ReaperRemove ==
    /\ reaper = "tornDown"
    /\ REMOVE_UNDER_LOCK => lockHolder = "none"
    /\ record' = "Freed"
    /\ reaper' = "done"
    /\ UNCHANGED <<lockHolder, reader, readFreed>>

Next ==
    \/ Exit
    \/ ReaderProbe
    \/ ReaderMiss
    \/ ReaderRead
    \/ ReaperTeardown
    \/ ReaperRemove
    \/ (reader = "done" /\ reaper = "done" /\ UNCHANGED vars)  \* both finished

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ record \in {"Live", "Exited", "Freed"}
    /\ lockHolder \in {"reader", "none"}
    /\ reader \in {"idle", "probed", "done"}
    /\ reaper \in {"waiting", "tornDown", "done"}
    /\ readFreed \in BOOLEAN

\* #482's property: a pointer a reader obtained from a live probe is never
\* read after the record behind it was handed back to the pool.
ReadsOnlyLiveRecords == ~readFreed

----------------------------------------------------------------------------
(* Constant initializers for Apalache. *)

CInitFixed == REMOVE_UNDER_LOCK = TRUE /\ READER_HOLDS_LOCK = TRUE
CInitUnfixed == REMOVE_UNDER_LOCK = FALSE /\ READER_HOLDS_LOCK = TRUE
CInitReaderUnlocked == REMOVE_UNDER_LOCK = TRUE /\ READER_HOLDS_LOCK = FALSE

=============================================================================
