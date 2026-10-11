------------------------- MODULE SharedRegionTransfer -------------------------
(* Partial region authority across an asynchronous protocol handoff.       *)
(* This is a first design layer, not implementation conformance evidence.  *)
(* Two abstract cells represent disjoint subregions; no byte/cache model,   *)
(* ring wrap, event marker, or device-specific completion decoding is here. *)
(* Fault controls: early publication, foreign completion, timeout reclaim, *)
(* and reinitialization after failed reset must each violate Safety.       *)
EXTENDS Integers, FiniteSets, TLC

CONSTANT
    \* @type: Int;
    FAULT

Cells == {0, 1}

VARIABLES
    \* @type: Str;
    phase,
    \* @type: Set(Int);
    available,
    \* @type: Set(Int);
    held,
    \* @type: Set(Int);
    prepared,
    \* @type: Set(Int);
    deviceActive,
    \* @type: Str;
    event,
    \* @type: Bool;
    invalidRead

vars == <<phase, available, held, prepared, deviceActive, event, invalidRead>>

Init ==
    /\ phase = "Idle"
    /\ available = Cells
    /\ held = {}
    /\ prepared = {}
    /\ deviceActive = {}
    /\ event = "None"
    /\ invalidRead = FALSE

(* A reservation receives exactly its own subregion authority. *)
Reserve(span) ==
    /\ phase = "Idle"
    /\ span # {}
    /\ span \subseteq available
    /\ phase' = "Reserved"
    /\ available' = available \ span
    /\ held' = span
    /\ prepared' = {}
    /\ event' = "None"
    /\ UNCHANGED <<deviceActive, invalidRead>>

(* Each preparation action is one cell write before descriptor publication. *)
Prepare(cell) ==
    /\ phase = "Reserved"
    /\ cell \in held \ prepared
    /\ prepared' = prepared \cup {cell}
    /\ UNCHANGED <<phase, available, held, deviceActive, event, invalidRead>>

(* Publication, not a later notification, removes CPU access permission. *)
Publish ==
    /\ phase = "Reserved"
    /\ (prepared = held \/ FAULT = 1)
    /\ phase' = "InFlight"
    /\ deviceActive' = held
    /\ UNCHANGED <<available, held, prepared, event, invalidRead>>

(* Device access can interleave immediately after publication. *)
DeviceRead ==
    /\ deviceActive # {}
    /\ ~invalidRead
    /\ invalidRead' = ~(deviceActive \subseteq prepared)
    /\ UNCHANGED <<phase, available, held, prepared, deviceActive, event>>

(* The environment promises completion ends access to this submitted span. *)
DeviceComplete ==
    /\ deviceActive # {}
    /\ deviceActive' = {}
    /\ event' = "Matching"
    /\ UNCHANGED <<phase, available, held, prepared, invalidRead>>

(* An unrelated event is not evidence about this span. *)
ForeignEvent ==
    /\ phase \in {"InFlight", "Unconfirmed"}
    /\ event = "None"
    /\ event' = "Foreign"
    /\ UNCHANGED <<phase, available, held, prepared, deviceActive, invalidRead>>

DiscardForeign ==
    /\ event = "Foreign"
    /\ FAULT # 2
    /\ event' = "None"
    /\ UNCHANGED <<phase, available, held, prepared, deviceActive, invalidRead>>

Observe ==
    /\ phase \in {"InFlight", "Unconfirmed"}
    /\ (event = "Matching" \/ (FAULT = 2 /\ event = "Foreign"))
    /\ phase' = "Idle"
    /\ available' = available \cup held
    /\ held' = {}
    /\ prepared' = {}
    /\ event' = "None"
    /\ UNCHANGED <<deviceActive, invalidRead>>

Timeout ==
    /\ phase = "InFlight"
    /\ phase' = IF FAULT = 3 THEN "Idle" ELSE "Unconfirmed"
    /\ available' = IF FAULT = 3 THEN available \cup held ELSE available
    /\ held' = IF FAULT = 3 THEN {} ELSE held
    /\ UNCHANGED <<prepared, deviceActive, event, invalidRead>>

ConfirmReset ==
    /\ phase = "Unconfirmed"
    /\ phase' = "Halted"
    /\ deviceActive' = {}
    /\ event' = "None"
    /\ UNCHANGED <<available, held, prepared, invalidRead>>

ResetFailed ==
    /\ phase = "Unconfirmed"
    /\ phase' = "Down"
    /\ UNCHANGED <<available, held, prepared, deviceActive, event, invalidRead>>

(* Fresh initialization requires confirmed quiescence. *)
Restart ==
    /\ (phase = "Halted" \/ (FAULT = 4 /\ phase = "Down"))
    /\ phase' = "Idle"
    /\ available' = Cells
    /\ held' = {}
    /\ prepared' = {}
    /\ event' = "None"
    /\ UNCHANGED <<deviceActive, invalidRead>>

Next ==
    \/ \E span \in SUBSET Cells : Reserve(span)
    \/ \E cell \in Cells : Prepare(cell)
    \/ Publish \/ DeviceRead \/ DeviceComplete \/ ForeignEvent
    \/ DiscardForeign \/ Observe \/ Timeout \/ ConfirmReset
    \/ ResetFailed \/ Restart

CpuAuthority == available \cup (IF phase = "Reserved" THEN held ELSE {})
NoOverlap == CpuAuthority \intersect deviceActive = {}
ReadyBeforeRead == ~invalidRead
Safety == NoOverlap /\ ReadyBeforeRead
TypeOK ==
    /\ phase \in {"Idle", "Reserved", "InFlight", "Unconfirmed", "Halted", "Down"}
    /\ available \subseteq Cells
    /\ held \subseteq Cells
    /\ prepared \subseteq Cells
    /\ deviceActive \subseteq Cells
    /\ event \in {"None", "Matching", "Foreign"}
    /\ invalidRead \in BOOLEAN

Spec == Init /\ [][Next]_vars

CInitFixed == FAULT = 0
CInitEarly == FAULT = 1
CInitForeign == FAULT = 2
CInitTimeout == FAULT = 3
CInitFailedReset == FAULT = 4
=============================================================================
