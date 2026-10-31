-------------------------- MODULE RecordLifetime --------------------------
EXTENDS Naturals
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
(* TAKE_EXCLUSIVE = FALSE (GitHub issue #1294): a second reaper. A deferred *)
(* reap of an ignored child and its parent in wait4 or its exit drain each  *)
(* find one zombie under an earlier hold. A take that leaves the record     *)
(* Exited mints a second owner in the gap between the first reaper's take   *)
(* and its removal, and TLC must find TeardownOnce violated. TRUE is the    *)
(* fix: the take moves the record to Reaping, so the loser's take misses.   *)
(*                                                                         *)
(* One action per critical section, as in every model here.               *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    REMOVE_UNDER_LOCK,
    \* @type: Bool;
    READER_HOLDS_LOCK,
    \* @type: Bool;
    EXEC_WRITES_UNDER_LOCK,
    \* @type: Bool;
    TAKE_EXCLUSIVE

VARIABLES
    \* @type: Str;
    record,     \* "Live" | "Exited" | "Reaping" | "Freed" | "Reused": the slot;
                \* Reused is a new process in it, reachable by the old address
    \* @type: Str;
    lockHolder, \* who holds the process-run lock across actions: "reader" | "none"
    \* @type: Str;
    reader,     \* "idle" | "probed" (holds a pointer) | "done"
    \* @type: Str;
    reaper,     \* "waiting" | "taken" | "tornDown" | "done"
    \* @type: Str;
    reaper2,    \* the second reaper, the same states
    \* @type: Int;
    teardowns,  \* how many teardowns ran for this one record
    \* @type: Bool;
    freedOther, \* did a removal free the slot's new occupant
    \* @type: Bool;
    readFreed,  \* did the reader ever read through a pointer to a freed record
    \* @type: Str;
    cmdline,    \* "old" | "torn" | "new": the record's command line
    \* @type: Bool;
    readTorn    \* did the reader ever copy a torn command line

vars == <<record, lockHolder, reader, reaper, reaper2, teardowns, freedOther,
          readFreed, cmdline, readTorn>>

\* What a step of one party leaves alone.
reapersUnchanged == UNCHANGED <<reaper, reaper2, teardowns, freedOther>>

Init ==
    /\ record = "Live"
    /\ lockHolder = "none"
    /\ reader = "idle"
    /\ reaper = "waiting"
    /\ reaper2 = "waiting"
    /\ teardowns = 0
    /\ freedOther = FALSE
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
    /\ UNCHANGED <<record, lockHolder, reader, readFreed, readTorn>>
    /\ reapersUnchanged

ExecWriteEnd ==
    /\ cmdline = "torn"
    /\ cmdline' = "new"
    /\ UNCHANGED <<record, lockHolder, reader, readFreed, readTorn>>
    /\ reapersUnchanged

(* The process exits. From here a reaper may take it. *)

Exit ==
    /\ record = "Live"
    /\ cmdline # "torn"
    /\ record' = "Exited"
    /\ UNCHANGED <<lockHolder, reader, readFreed, cmdline, readTorn>>
    /\ reapersUnchanged

(* The reader: take the lock (if it follows the rule), probe, read, release. *)

ReaderProbe ==
    /\ reader = "idle"
    /\ record \notin {"Freed", "Reused"} \* the handle's generation is live
    /\ IF READER_HOLDS_LOCK
         THEN /\ lockHolder = "none"
              /\ lockHolder' = "reader"
         ELSE UNCHANGED lockHolder
    /\ reader' = "probed"
    /\ UNCHANGED <<record, readFreed, cmdline, readTorn>>
    /\ reapersUnchanged

\* The pool answers NoPayload for a slot it already gave back, and a new
\* occupant has another generation: the reader reads nothing and is done.
ReaderMiss ==
    /\ reader = "idle"
    /\ record \in {"Freed", "Reused"}
    /\ reader' = "done"
    /\ UNCHANGED <<record, lockHolder, readFreed, cmdline, readTorn>>
    /\ reapersUnchanged

ReaderRead ==
    /\ reader = "probed"
    /\ readFreed' = (readFreed \/ record \in {"Freed", "Reused"})
    /\ readTorn' = (readTorn \/ cmdline = "torn")
    /\ lockHolder' = IF lockHolder = "reader" THEN "none" ELSE lockHolder
    /\ reader' = "done"
    /\ UNCHANGED <<record, cmdline>>
    /\ reapersUnchanged

(* A reaper: the take and the removal under the run lock, the teardown      *)
(* between them with no lock. It holds a handle found under an earlier      *)
(* hold, so a take that finds no Exited record misses and that reaper is    *)
(* done. The removal goes to the slot by address, whoever is in it (#1294).  *)

\* @type: (Str, Str) => Bool;
Take(self, next) ==
    /\ self = "waiting"
    /\ lockHolder = "none"
    /\ record = "Exited"
    /\ next = "taken"
    /\ record' = IF TAKE_EXCLUSIVE THEN "Reaping" ELSE record

\* @type: (Str, Str) => Bool;
Teardown(self, next) ==
    /\ self = "taken"
    /\ next = "tornDown"
    /\ teardowns' = teardowns + 1

\* @type: (Str, Str) => Bool;
Remove(self, next) ==
    /\ self = "tornDown"
    /\ REMOVE_UNDER_LOCK => lockHolder = "none"
    /\ next = "done"
    /\ freedOther' = (freedOther \/ record = "Reused")
    /\ record' = "Freed"

ReaperTake ==
    /\ Take(reaper, "taken")
    /\ reaper' = "taken"
    /\ UNCHANGED <<lockHolder, reader, reaper2, teardowns, freedOther,
                   readFreed, cmdline, readTorn>>

ReaperTeardown ==
    /\ Teardown(reaper, "tornDown")
    /\ reaper' = "tornDown"
    /\ UNCHANGED <<record, lockHolder, reader, reaper2, freedOther,
                   readFreed, cmdline, readTorn>>

ReaperRemove ==
    /\ Remove(reaper, "done")
    /\ reaper' = "done"
    /\ UNCHANGED <<lockHolder, reader, reaper2, teardowns,
                   readFreed, cmdline, readTorn>>

SecondReaperTake ==
    /\ Take(reaper2, "taken")
    /\ reaper2' = "taken"
    /\ UNCHANGED <<lockHolder, reader, reaper, teardowns, freedOther,
                   readFreed, cmdline, readTorn>>

\* The arm a loser takes: it found the record Exited under an earlier hold,
\* so a record not Exited now has been taken or removed since. Either reaper
\* can be the one that lost.
\* @type: (Str) => Bool;
Miss(self) ==
    /\ self = "waiting"
    /\ lockHolder = "none"
    /\ record \in {"Reaping", "Freed", "Reused"}

ReaperMiss ==
    /\ Miss(reaper)
    /\ reaper' = "done"
    /\ UNCHANGED <<record, lockHolder, reader, reaper2, teardowns, freedOther,
                   readFreed, cmdline, readTorn>>

SecondReaperMiss ==
    /\ Miss(reaper2)
    /\ reaper2' = "done"
    /\ UNCHANGED <<record, lockHolder, reader, reaper, teardowns, freedOther,
                   readFreed, cmdline, readTorn>>

SecondReaperTeardown ==
    /\ Teardown(reaper2, "tornDown")
    /\ reaper2' = "tornDown"
    /\ UNCHANGED <<record, lockHolder, reader, reaper, freedOther,
                   readFreed, cmdline, readTorn>>

SecondReaperRemove ==
    /\ Remove(reaper2, "done")
    /\ reaper2' = "done"
    /\ UNCHANGED <<lockHolder, reader, reaper, teardowns,
                   readFreed, cmdline, readTorn>>

\* The pool hands the slot to a new process.
SlotReuse ==
    /\ record = "Freed"
    /\ lockHolder = "none"
    /\ record' = "Reused"
    /\ UNCHANGED <<lockHolder, reader, readFreed, cmdline, readTorn>>
    /\ reapersUnchanged

Next ==
    \/ ExecWrite
    \/ ExecWriteEnd
    \/ Exit
    \/ ReaderProbe
    \/ ReaderMiss
    \/ ReaderRead
    \/ ReaperTake
    \/ ReaperMiss
    \/ ReaperTeardown
    \/ ReaperRemove
    \/ SecondReaperTake
    \/ SecondReaperMiss
    \/ SecondReaperTeardown
    \/ SecondReaperRemove
    \/ SlotReuse
    \/ (reader = "done" /\ reaper = "done" /\ reaper2 = "done" /\ UNCHANGED vars)  \* all finished

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ record \in {"Live", "Exited", "Reaping", "Freed", "Reused"}
    /\ lockHolder \in {"reader", "none"}
    /\ reader \in {"idle", "probed", "done"}
    /\ reaper \in {"waiting", "taken", "tornDown", "done"}
    /\ reaper2 \in {"waiting", "taken", "tornDown", "done"}
    /\ teardowns \in 0..2
    /\ freedOther \in BOOLEAN
    /\ readFreed \in BOOLEAN
    /\ cmdline \in {"old", "torn", "new"}
    /\ readTorn \in BOOLEAN

\* #482's property: a pointer a reader obtained from a live probe is never
\* read after the record behind it was handed back to the pool.
ReadsOnlyLiveRecords == ~readFreed

\* #618's property: a reader's copy of the command line is one image's,
\* never half of each.
NoTornRead == ~readTorn

\* #1294's properties: one record is torn down once, and a reaper frees only
\* the record it took, never the slot's next occupant.
TeardownOnce == teardowns <= 1
FreesOnlyItsOwn == ~freedOther

\* What Apalache's shallow check is given.
RecordInvariants ==
    ReadsOnlyLiveRecords /\ NoTornRead /\ TeardownOnce /\ FreesOnlyItsOwn

----------------------------------------------------------------------------
(* Constant initializers for Apalache. *)

CInitFixed ==
    REMOVE_UNDER_LOCK = TRUE /\ READER_HOLDS_LOCK = TRUE /\ EXEC_WRITES_UNDER_LOCK = TRUE
    /\ TAKE_EXCLUSIVE = TRUE
CInitUnfixed ==
    REMOVE_UNDER_LOCK = FALSE /\ READER_HOLDS_LOCK = TRUE /\ EXEC_WRITES_UNDER_LOCK = TRUE
    /\ TAKE_EXCLUSIVE = TRUE
CInitReaderUnlocked ==
    REMOVE_UNDER_LOCK = TRUE /\ READER_HOLDS_LOCK = FALSE /\ EXEC_WRITES_UNDER_LOCK = TRUE
    /\ TAKE_EXCLUSIVE = TRUE
CInitExecUnlocked ==
    REMOVE_UNDER_LOCK = TRUE /\ READER_HOLDS_LOCK = TRUE /\ EXEC_WRITES_UNDER_LOCK = FALSE
    /\ TAKE_EXCLUSIVE = TRUE
CInitTakeShared ==
    REMOVE_UNDER_LOCK = TRUE /\ READER_HOLDS_LOCK = TRUE /\ EXEC_WRITES_UNDER_LOCK = TRUE
    /\ TAKE_EXCLUSIVE = FALSE

=============================================================================
