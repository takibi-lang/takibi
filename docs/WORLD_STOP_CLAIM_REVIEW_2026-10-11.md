# World-stop claim correction, 2026-10-11

## Boundary and assessment

This is an incremental logic correction, not a feature or allocator stage.
The maintained boot workload, pool sizes, persistent record layouts, atomic
gate representation, participant mask and reserved memory are unchanged.
WorldStopClaimResult is a local result, not additional persistent storage.
The caller retains the existing one-second retry deadline and interrupt-mask
lifetime. Reuse the previous linked-kernel and pool evidence in the space
checkpoint; no payload, pool metadata or reservation reduction is claimed.
The next completed feature or changed allocation workload needs measurement.

## Defect follow-up

A boolean failed CAS and a later holder load were treated as one observation.
A CPU-start reservation released between them was falsely reported as a stop
holder, so the peer crash did not retry and could not inspect shared state.
Only a successful CAS grants the claim. The four-case must-use result makes
callers handle the released observation, but the compiler does not prove the
atomic implementation or bounded progress; those remain reviewed code.

The prior start-window test held CPU 1 at its next claim call, after the
holder load had already seen the reservation. It therefore missed a release
between the failed CAS and that load. The new QEMU start-release fixture
stops there, confirms the gate is start-held, lets CPU 0 finish, confirms the
gate is zero, then resumes both. The old implementation exits 1 with the
peer-stop assertion and Busy diagnostic; the corrected implementation passes
three independent samples. The original allcheck capture has no claim
observation, so this reproduction does not prove it was the only possible
cause of that occurrence.

All claim-helper callers were reviewed: subset stop, machine stop, CPU-start
reservation and the held-stop negative probe. Only machine stop retries;
the others deliberately remain nonblocking. No hosted copy exists. The
WorldStop action map was reviewed and restamped: its claim abstraction and
NoUnstoppedRead invariant do not assert bounded acquisition success. TLC and
Apalache pass the maintained model lane; this is bounded safety evidence.
GDB source-line breakpoints and per-vCPU scheduling preserve the relevant
window without production diagnostic fields or UART perturbation.

A general atomic result carrying the value observed by CAS is a candidate
for the protocol/type work. It would eliminate this helper's second read,
but would not prove that a failed CAS grants authority or that a bounded wait
succeeds. No new compiler capability is implemented by this correction.
