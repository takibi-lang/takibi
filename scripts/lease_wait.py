"""Whether a console transcript shows its runner still waiting for vCPUs.

GitHub issue #719: the shell runners (run_kernel_shell_qemu.sh) take their
vCPU lease after the driver reading their terminal has started its boot
deadline. At four vCPUs a busy host makes that wait long enough to spend the
whole deadline before QEMU starts, reported as "the shell never became
ready". scripts/vcpu_lease.sh prints a `[lease] waiting` line whenever it
waits and `[lease] got` once it holds the slots; a driver restarts its boot
deadline while the first is the newer. The lease has its own timeout, so the
wait stays bounded.
"""

WAITING = b"[lease] waiting"
GOT = b"[lease] got "


def lease_pending(transcript: bytes) -> bool:
    return transcript.rfind(WAITING) > transcript.rfind(GOT)
