# Kernel-side test machinery

This inventory describes test-only behavior and evidence in the maintained
kernel as of 2026-09-24. DDB and boot probes that measure kernel internals,
including contention, allocator, and virtio probes, are ordinary kernel
evidence and are outside this inventory.

## Userspace checks for ext2 behavior

The checks that exercise Linux-visible directory operations run through
BusyBox in the shared ash fixture, `kernel/tests/common/ash/ash.stdin`:

| Behavior | Userspace check |
|---|---|
| `mkdirat` and `unlinkat` for `mkdir`, `rmdir`, and `rm` | Creates, checks error cases, and removes entries in `/etc` on both platform lanes |
| `renameat` for `mv` | Renames files and a directory, replaces a file, and checks refused cases |
| Directory growth, enumeration, and dead-record reuse | Creates five 200-byte child names directly in `/etc`, lists all five, removes the last one, recreates that same 200-byte name, and lists again. BusyBox `stat` observes `/etc` at `st_size=2048` before and after reuse through `newfstatat` |
| File reads, including multiple data blocks | BusyBox `cat` checks `/hello.txt` and the complete 3200-byte `/large.txt` |
| File truncation and extension | `/bin/user_payload` opens `/mutable.txt`, writes `tiny\n`, reads it back and checks EOF, then writes and reads `extended ext2\n` and checks EOF again |

The shell outputs for the long directory names are compared exactly. This
proves `ls` walks both directory blocks and that userspace can remove an
entry from the newly allocated block. `newfstatat` exposes the
directory's `st_size`; the ash fixture verifies the second block remains the
same size after the dead record is reused. It removes every probe directory
but leaves `/etc` grown on disk. The QEMU runner checks the guest's whole disk
with `e2fsck` after the session.

RPi5 provisions the ext2 root onto the USB medium, verifies the copy, and
mounts that same device as the root filesystem. The shared userspace checks
therefore exercise the USB backend directly; there is no separate unmounted
USB mutation fixture.

## Direct ext2 fixture entries that remain

`kernel/init/ext2_fixture.tkb` runs the remaining checks before userspace
starts:

| Probe | Why it remains in the kernel fixture |
|---|---|
| `ext2_bitmap_roundtrip_check` | Allocates and releases a block and inode, then checks the ext2 free counts returned to their starting values. Those bitmap counts are not exposed by a Linux syscall. |
| `ext2_owner_roundtrip_check` | Checks that linear block and inode owners can be claimed and returned. Owner tokens are a kernel-side resource contract. |
| `ext2_create_check` and `ext2_create_in_directory_check` | Exercise regular-file creation through the ext2 API. `openat` does not implement `O_CREAT`, so userspace cannot reach these operations. |
| `ext2_read_fast_symlink` for `/latest` | The ext2 path walker does not follow symlinks, so userspace cannot read the target through this path yet. |

The direct reads of `/hello.txt` and `/large.txt`, the directory-growth
fixture, and the write/truncate check for `/mutable.txt` were removed. The
ash fixture now checks the first two through `cat` and the directory through
`mkdir`, `rmdir`, `getdents64`, and `stat`; the EL0 payload checks truncate and
extend through `openat`, `write`, `read`, and `close`. The old file-syscall
counters and partial-write flag were removed at the same time: userspace now
prints success lines only after checking the syscall return values.

## Test-only syscalls

The private AArch64 syscall numbers are 451 through 453 in
`kernel/kernel/syscall.tkb`. They are not Linux ABI promises.

| Number | Name | Why a userspace fixture uses it |
|---|---|---|
| 451 | UART RX wait | The forked child in `/bin/user_payload` blocks for serial bytes so the parent can stay runnable. The fixture needs a single explicit wait/wake point to prove the scheduler moves that child from blocked to ready. |
| 452 | Parent progress | The parent reports after its compute section while the child is still blocked. This proves the two-process ordering that the UART scheduler probe requires; ordinary userspace output cannot establish the child's kernel wait state. |
| 453 | Workload progress | Busy-pair and peer workloads report checksums, completed rounds, and wake milestones. The kernel compares the reports and directs the fixture's stop, exit, or respawn boundary. |

## Syscall evidence counters

`kernel/kernel/syscall_test_evidence.tkb` has twelve counters and one socket
fixture phase flag. The socket counters stop recording after the core-0
fixture, before concurrent HTTPd workers start.
They only feed test messages or one-shot wait markers; syscall behavior does
not branch on these counters.

The former open/read/write/close counters and partial-write flag were removed.
The EL0 payload now checks file bytes and EOF through the syscall ABI and
checks the 1460-byte short write followed by the remaining one-byte write;
its success lines replace the old kernel-generated verdicts.

| Fields | Why kernel-side evidence remains useful |
|---|---|
| `ppoll_uart_waits`, `ppoll_uart_blocks`, `read_uart_waits` | Emit one-time markers when the interactive shell reaches the UART wait path, distinguishing a real block from a retry. The host driver uses the marker to send input at the intended point. |
| `socket_calls` | Requires at least one socket while allowing extra BusyBox syslog attempts that do not belong to the fixture. |
| `bind_calls`, `listen_calls` | Require the fixture's listener setup to occur exactly once. |
| `accept_calls`, `accept_capability_roundtrips` | Require two accepts and verify the kernel's accepted-connection ownership handoff for each one. |
| `socket_close_calls`, `connected_close_calls` | Check the listener and both connected descriptors are closed after the fixture. |
| `connected_read_calls`, `connected_write_calls` | Check the expected operations reached each connected socket handler while two connections overlap. The host peer checks the response bytes separately. |

## Persistent-shell lifecycle checkpoints

Four log-once checkpoints in `kernel/kernel/syscall_test_lifecycle.tkb`
report the persistent shell's fork child pid, the child's first scheduled
syscall, exec preparation, and exec commit. The host can locate the last
completed kernel boundary when a lane stalls; a shell's output cannot report
which internal transition it reached.

## BusyBox exec image fallback

When an exec path has already resolved but `argv[0]` is not an ext2 image
name, the kernel maps the saved static BusyBox image. BusyBox ash can find a
bare applet name through `PATH` while passing that bare name as `argv[0]`;
reusing the BusyBox image preserves its multi-call dispatch. A missing exec
pathname is still reported as `ENOENT` before this fallback is considered.
This is required launch behavior for the selected userspace, not a test-only
syscall.

## Build-check decision

The source audit measured three private syscall numbers, twelve evidence
counters, one phase flag, and four lifecycle
checkpoint functions. A name-based check could catch additions that follow
those exact naming patterns, but it would miss a new hook named differently,
a test-only branch added to an existing function, or a stale reason in this
document. Requiring a second list of identifiers in a build script would not
enforce the semantic distinction between a userspace check and a kernel
internal probe, so this inventory remains a review item and has no build gate.
