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
(* the historical reader omitted: a reader of another process holds the   *)
(* run lock from probe to read. With the fix in place and this assumption *)
(* broken, TLC must find the violation again -- the fix alone is not      *)
(* enough, and this variant is what says so.                               *)
(*                                                                         *)
(* EXEC_WRITES_UNDER_LOCK = FALSE (GitHub issue #618): execve rewrites    *)
(* the record's command line while the process is live, and a reader      *)
(* copies it out -- procfs's snapshot. Written outside the run lock, the   *)
(* rewrite is two steps a locked reader can fall between, and TLC must    *)
(* find NoTornRead violated: a copy that is half the old image's command   *)
(* line and half the new one's.                                            *)
(*                                                                         *)
(* One action per critical section, as in every model here.               *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    REMOVE_UNDER_LOCK,
    \* @type: Bool;
    READER_HOLDS_LOCK,
    \* @type: Bool;
    EXEC_WRITES_UNDER_LOCK

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
    readFreed,  \* did the reader ever read through a pointer to a freed record
    \* @type: Str;
    cmdline,    \* "old" | "torn" | "new": the record's command line
    \* @type: Bool;
    readTorn    \* did the reader ever copy a torn command line

vars == <<record, lockHolder, reader, reaper, readFreed, cmdline, readTorn>>

Init ==
    /\ record = "Live"
    /\ lockHolder = "none"
    /\ reader = "idle"
    /\ reaper = "waiting"
    /\ readFreed = FALSE
    /\ cmdline = "old"
    /\ readTorn = FALSE

----------------------------------------------------------------------------
(* execve rewrites the live process's command line: one critical section *)
(* under the run lock, or, outside it, two steps a reader can fall between.*)

ExecWrite ==
    /\ record = "Live"
    /\ cmdline = "old"
    /\ IF EXEC_WRITES_UNDER_LOCK
         THEN /\ lockHolder = "none"
              /\ cmdline' = "new"
         ELSE cmdline' = "torn"
    /\ UNCHANGED <<record, lockHolder, reader, reaper, readFreed, readTorn>>

ExecWriteEnd ==
    /\ cmdline = "torn"
    /\ cmdline' = "new"
    /\ UNCHANGED <<record, lockHolder, reader, reaper, readFreed, readTorn>>

(* The process exits. From here a reaper may take it. *)

Exit ==
    /\ record = "Live"
    /\ cmdline # "torn"
    /\ record' = "Exited"
    /\ UNCHANGED <<lockHolder, reader, reaper, readFreed, cmdline, readTorn>>

(* The reader: take the lock (if it follows the rule), probe, read, release. *)

ReaderProbe ==
    /\ reader = "idle"
    /\ record # "Freed"          \* the pool answers Live for a slot it holds
    /\ IF READER_HOLDS_LOCK
         THEN /\ lockHolder = "none"
              /\ lockHolder' = "reader"
         ELSE UNCHANGED lockHolder
    /\ reader' = "probed"
    /\ UNCHANGED <<record, reaper, readFreed, cmdline, readTorn>>

\* The pool answers NoPayload for a slot it already gave back: the reader
\* reads nothing and is done.
ReaderMiss ==
    /\ reader = "idle"
    /\ record = "Freed"
    /\ reader' = "done"
    /\ UNCHANGED <<record, lockHolder, reaper, readFreed, cmdline, readTorn>>

ReaderRead ==
    /\ reader = "probed"
    /\ readFreed' = (readFreed \/ record = "Freed")
    /\ readTorn' = (readTorn \/ cmdline = "torn")
    /\ lockHolder' = IF lockHolder = "reader" THEN "none" ELSE lockHolder
    /\ reader' = "done"
    /\ UNCHANGED <<record, reaper, cmdline>>

(* The reaper: the teardown needs no lock; the removal does, when fixed. *)

ReaperTeardown ==
    /\ reaper = "waiting"
    /\ record = "Exited"
    /\ reaper' = "tornDown"
    /\ UNCHANGED <<record, lockHolder, reader, readFreed, cmdline, readTorn>>

ReaperRemove ==
    /\ reaper = "tornDown"
    /\ REMOVE_UNDER_LOCK => lockHolder = "none"
    /\ record' = "Freed"
    /\ reaper' = "done"
    /\ UNCHANGED <<lockHolder, reader, readFreed, cmdline, readTorn>>

Next ==
    \/ ExecWrite
    \/ ExecWriteEnd
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
    /\ cmdline \in {"old", "torn", "new"}
    /\ readTorn \in BOOLEAN

\* #482's property: a pointer a reader obtained from a live probe is never
\* read after the record behind it was handed back to the pool.
ReadsOnlyLiveRecords == ~readFreed

\* #618's property: a reader's copy of the command line is one image's,
\* never half of each.
NoTornRead == ~readTorn

\* What Apalache's shallow check is given.
RecordInvariants == ReadsOnlyLiveRecords /\ NoTornRead

----------------------------------------------------------------------------
(* Constant initializers for Apalache. *)

CInitFixed ==
    REMOVE_UNDER_LOCK = TRUE /\ READER_HOLDS_LOCK = TRUE /\ EXEC_WRITES_UNDER_LOCK = TRUE
CInitUnfixed ==
    REMOVE_UNDER_LOCK = FALSE /\ READER_HOLDS_LOCK = TRUE /\ EXEC_WRITES_UNDER_LOCK = TRUE
CInitReaderUnlocked ==
    REMOVE_UNDER_LOCK = TRUE /\ READER_HOLDS_LOCK = FALSE /\ EXEC_WRITES_UNDER_LOCK = TRUE
CInitExecUnlocked ==
    REMOVE_UNDER_LOCK = TRUE /\ READER_HOLDS_LOCK = TRUE /\ EXEC_WRITES_UNDER_LOCK = FALSE

=============================================================================
