------------------------ MODULE FixedDmaOwnership ------------------------
(***************************************************************************)
(* One fixed receive allocation and its explicit linear authority. The    *)
(* stable slot starts with the only CPU token. A synchronous request takes *)
(* it, submits it to the device, and can recover CPU access only after an  *)
(* observed completion or a confirmed reset. A timeout alone gives no      *)
(* information about whether the device can still write.                  *)
(*                                                                         *)
(* TIMEOUT_RETURNS_CPU = TRUE models the old, invalid shortcut of treating *)
(* an unobserved timeout as a completion. CpuAccess then violates safety.  *)
(* The model does not prove compiler alias tracking, cache maintenance,    *)
(* or the hardware's reset contract.                                       *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    TIMEOUT_RETURNS_CPU

VARIABLES
    \* @type: Str;
    slot,          \* "Cpu" | "Empty" | "Dma": persistent authority storage
    \* @type: Str;
    token,         \* "None" | "Cpu" | "Dma": local linear authority
    \* @type: Bool;
    deviceActive,  \* the controller may still write the allocation
    \* @type: Str;
    evidence,      \* "None" | "Complete" | "TimedOut" | "Reset"
    \* @type: Bool;
    invalidAccess  \* CPU touched memory while the device could write

vars == <<slot, token, deviceActive, evidence, invalidAccess>>

Init ==
    /\ slot = "Cpu"
    /\ token = "None"
    /\ deviceActive = FALSE
    /\ evidence = "None"
    /\ invalidAccess = FALSE

(* Each slot exchange is one guarded critical section. *)
TakeCpu ==
    /\ slot = "Cpu"
    /\ token = "None"
    /\ slot' = "Empty"
    /\ token' = "Cpu"
    /\ UNCHANGED <<deviceActive, evidence, invalidAccess>>

PutCpu ==
    /\ slot = "Empty"
    /\ token = "Cpu"
    /\ slot' = "Cpu"
    /\ token' = "None"
    /\ UNCHANGED <<deviceActive, evidence, invalidAccess>>

(* A failed reset leaves the device token in the slot and disables reuse. *)
PutDma ==
    /\ slot = "Empty"
    /\ token = "Dma"
    /\ evidence = "ResetFailed"
    /\ slot' = "Dma"
    /\ token' = "None"
    /\ UNCHANGED <<deviceActive, evidence, invalidAccess>>

(* The prepare and submission step consumes CPU authority. *)
Submit ==
    /\ token = "Cpu"
    /\ ~deviceActive
    /\ token' = "Dma"
    /\ deviceActive' = TRUE
    /\ evidence' = "None"
    /\ UNCHANGED <<slot, invalidAccess>>

(* A completed request, including a completed error, no longer writes. *)
ObserveCompletion ==
    /\ token = "Dma"
    /\ deviceActive
    /\ deviceActive' = FALSE
    /\ evidence' = "Complete"
    /\ UNCHANGED <<slot, token, invalidAccess>>

(* A missing event is not evidence that the device stopped. *)
Timeout ==
    /\ token = "Dma"
    /\ evidence = "None"
    /\ evidence' = "TimedOut"
    /\ UNCHANGED <<slot, token, deviceActive, invalidAccess>>

(* The reset action represents confirmed quiescence, not a reset request. *)
ConfirmReset ==
    /\ token = "Dma"
    /\ evidence = "TimedOut"
    /\ deviceActive' = FALSE
    /\ evidence' = "Reset"
    /\ UNCHANGED <<slot, token, invalidAccess>>

ResetFailed ==
    /\ token = "Dma"
    /\ evidence = "TimedOut"
    /\ evidence' = "ResetFailed"
    /\ UNCHANGED <<slot, token, deviceActive, invalidAccess>>

Finish ==
    /\ token = "Dma"
    /\ (evidence \in {"Complete", "Reset"}
        \/ (TIMEOUT_RETURNS_CPU /\ evidence = "TimedOut"))
    /\ token' = "Cpu"
    /\ UNCHANGED <<slot, deviceActive, evidence, invalidAccess>>

CpuAccess ==
    /\ token = "Cpu"
    /\ invalidAccess' = (invalidAccess \/ deviceActive)
    /\ UNCHANGED <<slot, token, deviceActive, evidence>>

(* The controller is unusable and rejects every later request. *)
Disabled ==
    /\ slot = "Dma"
    /\ token = "None"
    /\ UNCHANGED vars

Next ==
    \/ TakeCpu
    \/ PutCpu
    \/ PutDma
    \/ Submit
    \/ ObserveCompletion
    \/ Timeout
    \/ ConfirmReset
    \/ ResetFailed
    \/ Finish
    \/ CpuAccess
    \/ Disabled

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ slot \in {"Cpu", "Empty", "Dma"}
    /\ token \in {"None", "Cpu", "Dma"}
    /\ deviceActive \in BOOLEAN
    /\ evidence \in {"None", "Complete", "TimedOut", "Reset", "ResetFailed"}
    /\ invalidAccess \in BOOLEAN

UniqueAuthority == (slot = "Empty") <=> (token # "None")
NoCpuAccessWhileDeviceMayWrite == ~invalidAccess
Safety == UniqueAuthority /\ NoCpuAccessWhileDeviceMayWrite

CInitFixed == TIMEOUT_RETURNS_CPU = FALSE
CInitUnfixed == TIMEOUT_RETURNS_CPU = TRUE

=============================================================================
