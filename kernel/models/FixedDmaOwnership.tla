------------------------ MODULE FixedDmaOwnership ------------------------
(***************************************************************************)
(* One fixed RX or TX allocation and its explicit linear authority. The   *)
(* stable slot starts with the only CPU token. A synchronous request takes *)
(* it, submits it to the device, and can recover CPU access only after an  *)
(* observed completion or a confirmed reset. A timeout alone gives no      *)
(* information about whether the device can still access memory.         *)
(*                                                                         *)
(* TIMEOUT_RETURNS_CPU = TRUE models the old, invalid shortcut of treating *)
(* an unobserved timeout as a completion; even CPU authority is invalid.  *)
(* The model does not prove compiler alias tracking, cache maintenance,    *)
(* or the hardware's reset contract.                                       *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    TIMEOUT_RETURNS_CPU,
    \* @type: Bool;
    HALT_FAILURE_RETURNS_CPU,
    \* @type: Bool;
    GEM_TX_POLICY,
    \* @type: Bool;
    CHECK_TX_DOWN

VARIABLES
    \* @type: Str;
    slot,          \* "Cpu" | "Empty" | "Dma": persistent authority storage
    \* @type: Str;
    token,         \* "None" | "Cpu" | "Dma": local linear authority
    \* @type: Bool;
    deviceActive,  \* the controller may still read or write the allocation
    \* @type: Str;
    evidence,      \* "None" | "Complete" | "TimedOut" | "Reset"
    \* @type: Bool;
    invalidAccess, \* CPU touched memory while the device could access it
    \* @type: Bool;
    txDown,        \* GEM permanently stops admitting requests after timeout
    \* @type: Bool;
    invalidReuse   \* a later GEM request was admitted after halt

vars == <<slot, token, deviceActive, evidence, invalidAccess, txDown, invalidReuse>>

Init ==
    /\ slot = "Cpu"
    /\ token = "None"
    /\ deviceActive = FALSE
    /\ evidence = "None"
    /\ invalidAccess = FALSE
    /\ txDown = FALSE
    /\ invalidReuse = FALSE

(* Each slot exchange is one guarded critical section. *)
TakeCpu ==
    /\ slot = "Cpu"
    /\ token = "None"
    /\ evidence' = "None"
    /\ slot' = "Empty"
    /\ token' = "Cpu"
    /\ UNCHANGED <<deviceActive, invalidAccess, txDown, invalidReuse>>

PutCpu ==
    /\ slot = "Empty"
    /\ token = "Cpu"
    /\ slot' = "Cpu"
    /\ token' = "None"
    /\ UNCHANGED <<deviceActive, evidence, invalidAccess, txDown, invalidReuse>>

(* A failed reset leaves the device token in the slot and disables reuse. *)
PutDma ==
    /\ slot = "Empty"
    /\ token = "Dma"
    /\ evidence = "ResetFailed"
    /\ slot' = "Dma"
    /\ token' = "None"
    /\ UNCHANGED <<deviceActive, evidence, invalidAccess, txDown, invalidReuse>>

(* The prepare and submission step consumes CPU authority. *)
Submit ==
    /\ token = "Cpu"
    /\ (~GEM_TX_POLICY \/ evidence = "None")
    /\ (~GEM_TX_POLICY \/ ~CHECK_TX_DOWN \/ ~txDown)
    /\ invalidReuse' = (invalidReuse \/ (GEM_TX_POLICY /\ txDown))
    /\ ~deviceActive
    /\ token' = "Dma"
    /\ deviceActive' = TRUE
    /\ evidence' = "None"
    /\ UNCHANGED <<slot, invalidAccess, txDown>>

(* A completed request, including a completed error, no longer writes. *)
ObserveCompletion ==
    /\ token = "Dma"
    /\ deviceActive
    /\ (~GEM_TX_POLICY \/ evidence = "None")
    /\ deviceActive' = FALSE
    /\ evidence' = "Complete"
    /\ UNCHANGED <<slot, token, invalidAccess, txDown, invalidReuse>>

(* A missing event is not evidence that the device stopped. *)
Timeout ==
    /\ token = "Dma"
    /\ evidence = "None"
    /\ evidence' = "TimedOut"
    /\ txDown' = (txDown \/ GEM_TX_POLICY)
    /\ UNCHANGED <<slot, token, deviceActive, invalidAccess, invalidReuse>>

(* The reset action represents confirmed quiescence, not a reset request. *)
ConfirmReset ==
    /\ token = "Dma"
    /\ evidence = "TimedOut"
    /\ deviceActive' = FALSE
    /\ evidence' = "Reset"
    /\ UNCHANGED <<slot, token, invalidAccess, txDown, invalidReuse>>

ResetFailed ==
    /\ token = "Dma"
    /\ evidence = "TimedOut"
    /\ evidence' = "ResetFailed"
    /\ UNCHANGED <<slot, token, deviceActive, invalidAccess, txDown, invalidReuse>>

Finish ==
    /\ token = "Dma"
    /\ (evidence \in {"Complete", "Reset"}
        \/ (TIMEOUT_RETURNS_CPU /\ evidence = "TimedOut")
        \/ (HALT_FAILURE_RETURNS_CPU /\ evidence = "ResetFailed"))
    /\ token' = "Cpu"
    /\ UNCHANGED <<slot, deviceActive, evidence, invalidAccess, txDown, invalidReuse>>

CpuAccess ==
    /\ token = "Cpu"
    /\ (~GEM_TX_POLICY \/ evidence = "None")
    /\ (~GEM_TX_POLICY \/ ~CHECK_TX_DOWN \/ ~txDown)
    /\ invalidAccess' = (invalidAccess \/ deviceActive)
    /\ invalidReuse' = (invalidReuse \/ (GEM_TX_POLICY /\ txDown))
    /\ UNCHANGED <<slot, token, deviceActive, evidence, txDown>>

(* The controller is unusable and rejects every later request. *)
Disabled ==
    /\ (slot = "Dma" \/ (GEM_TX_POLICY /\ txDown /\ slot = "Cpu"))
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
    /\ txDown \in BOOLEAN
    /\ invalidReuse \in BOOLEAN

UniqueAuthority == (slot = "Empty") <=> (token # "None")
NoCpuAccessWhileDeviceMayWrite == ~invalidAccess
NoPrematureCpuAuthority == deviceActive => (slot # "Cpu" /\ token # "Cpu")
NoReuseAfterHalt == ~invalidReuse
Safety == UniqueAuthority /\ NoCpuAccessWhileDeviceMayWrite
          /\ NoPrematureCpuAuthority /\ NoReuseAfterHalt

CInitPolicy(timeout, failed, gem, checkDown) ==
    /\ TIMEOUT_RETURNS_CPU = timeout
    /\ HALT_FAILURE_RETURNS_CPU = failed
    /\ GEM_TX_POLICY = gem
    /\ CHECK_TX_DOWN = checkDown

CInitFixed == CInitPolicy(FALSE, FALSE, FALSE, TRUE)
CInitUnfixed == CInitPolicy(TRUE, FALSE, FALSE, TRUE)
CInitGemFixed == CInitPolicy(FALSE, FALSE, TRUE, TRUE)
CInitGemTimeout == CInitPolicy(TRUE, FALSE, TRUE, TRUE)
CInitGemFailedHalt == CInitPolicy(FALSE, TRUE, TRUE, TRUE)
CInitGemReuse == CInitPolicy(FALSE, FALSE, TRUE, FALSE)

=============================================================================
