# Handle boundary audit, 2026-10-29 (GitHub issue #1224)

Question (maintainer, on #709/#710): generation-numbered slots detect
use-after-free and ABA but are not secret. Are they safe if user space could
learn a slot's generation? They are, provided (1) no handle (slot index or
generation) ever reaches user space, and (2) no user-supplied number is ever
turned into a handle without a lookup the kernel owns. This audit checks both
directions at the syscall boundary of `kernel/` at commit 34de2e42.

Read-only: no code changed.

## Method

- Every write to user memory goes through `kernel/mm/user_memory.tkb`
  (`copy_to_user` :401, `copy_to_user_span` :431, `user_write_byte` :448,
  `user_write_u32` :458, `user_write_u64` :469, `user_write_u16` :507).
  A tree-wide grep shows that outside that file they are called only from
  `kernel/kernel/syscall.tkb`. Every call site (about 130) was read, and the
  value each one writes was traced to its origin.
- Every register return: `SyscallAction::Resume(value)` and
  `el0_context_set_x0` (syscall.tkb:4539, 4635, 4828, 4862, 5013, 5026).
  Every Resume argument that is not a constant or an errno was traced.
- `/proc` text (`kernel/fs/procfs.tkb`), `syslog(2)` (the kernel log ring,
  syscall.tkb:4546), siginfo in the signal frame (syscall.tkb:6329-6353),
  ioctl replies (syscall.tkb:4116), and the getdents, stat and statfs records.
- Inbound: every place an argument register reaches a lookup. That covers
  fds, pids, paths, and the Takibi-private syscalls 451-453.
- `--emit-call-graph` and `--emit-globals` were not needed. No kernel image
  is built in this worktree. For direction 1, writes to user memory go only
  through the primitives above, so a grep for their callers finds every
  path. For direction 2, the only handle constructors that syscalls reach
  (`scheduled_process_handle_of_slot`, `unified_object_handle_new`,
  `tcp_connection_take`, `pipe_take`) take arguments the kernel computes.

## Findings

| # | Severity | Direction | Finding |
|---|---|---|---|
| F1 | none (clean) | out | No slot index or generation of a region_table, region_pool, intrusive_pool, process, fd, pipe, socket/TCP connection or inode-cache record is written to user memory or returned in a register. |
| F2 | none (clean) | in | No syscall accepts a raw slot or generation. A kernel-owned lookup resolves every number user space passes in. |
| F3 | low | out (side channel) | One monotonic pid counter for the whole system. |
| F4 | low | out (info) | Kernel text addresses in `/proc/takibi/profile` and in the `syslog` ring. |
| F5 | low | out (info) | `syslog(READ_ALL)` has no privilege check. Any log line that ever prints a slot or generation becomes visible to user space. |
| F6 | info | out (side channel) | Counters that reveal allocation activity, as Linux's also do. |
| F7 | low (boundary) | out | The pid counter has no exhaustion contract and can exceed `pid_t`. |
| F8 | info (network) | out | The TCP initial sequence number is a constant. |

### F1: nothing handle-shaped crosses outbound

Since #1228 a build check keeps this finding true lexically:
`scripts/check_handle_boundary.py` refuses a slot or generation word in the
written value of any sink listed under Method.

Each value written, by kind:

- Descriptors: the `pipe2` fds (syscall.tkb:2840-2841) and every returned
  fd. An fd is an index into the caller's own descriptor table
  (`fd_slot_index`, fd_table.tkb:386). That is the Linux ABI itself, not a
  pool slot. The SharedObject slot and generation behind it
  (`unified_object_handle_new`, fd_table.tkb:1263) stay in kernel memory.
- pids: the wait4 return (syscall.tkb:4539), the clone return (4862),
  siginfo `si_pid` (6343-6344, 6351-6352) and `/proc/<pid>/stat`
  (procfs.tkb:330-341). A pid comes from a monotonic counter
  (process.tkb:880-886) and does not depend on the process pool slot.
  Mapping a slot to its pid is a field read (`scheduled_process_pid_of_slot`,
  process.tkb:2297).
- Inode numbers: `newfstatat` st_ino (syscall.tkb:7418, 7466, 7490, 7508)
  and getdents64 d_ino (1244, 9775, 9904). An ext2 number is the on-disk
  inode number that comes from `ext2_lookup_path_from` or a directory
  entry, not a cache slot. A procfs number is `0xF1000000 + pid*4 + kind`
  (procfs.tkb:34-38), computed from the pid.
- getdents d_off: an ext2 directory byte offset (9907), or for procfs
  `pid | PROCFS_ROOT_AFTER_TAKIBI` (9778, procfs.tkb:30). Both are offsets
  or pids, not slots.
- statfs (1546-1562): the magic number, block size, free counts and fsid.
- mmap return `USER_TEXT_VA + first*PAGE_SIZE` (syscall.tkb:1365-1373): a
  virtual address in the caller's own layout.
- Signal frame (6287-6385): user registers, the signal mask, the altstack
  and FPSIMD. Frame validation in the kernel uses the process generation
  (`kernel_process_entry_generation`, process.tkb:4682), but the generation
  stays in kernel memory: `frame_ref_from_el0_entry` (syscall.tkb:4675)
  never writes it to the user frame.
- A listener's pending `(slot, generation)` (syscall.tkb:2013-2033,
  5468-5628) and a connection's identity (2087, 3018, 3293) stay in
  SharedObject fields. They are passed only to `tcp_connection_take`.
- Plain values: ioctl (winsize constants at 4133-4134, termios bytes), poll
  revents (3981), wait status (4523, 8530), timers and clocks (6149, 6513,
  8617, 8657), sigaction and sigprocmask (8705-8786), getcpu and affinity
  (8898-8945), prlimit (7614), uname (7707).
- Data copies: the pipe buffer (2630, 2647), TCP payload (3373, 3511, 3602,
  3665) and the log ring (4590).
- Error paths return only errno constants. A short or partial write returns
  a byte count.

### F2: every inbound number gets a kernel-owned lookup

- An fd is looked up in the caller's own table (`fd_block_lookup`,
  fd_table.tkb:497; `unified_socket_lookup` :1873; `unified_pipe_lookup`
  :2032). The object's generation is checked against the pool
  (`unified_object_matches`, fd_table.tkb:929).
- A pid is mapped to a slot by a search under the run lock
  (`scheduled_process_slot_for_pid_locked`, process.tkb:2333). The callers
  are kill (`kernel_process_signal_send`, process.tkb:9260;
  syscall.tkb:8832), wait4 (8404, which searches only the caller's
  children), affinity (process.tkb:6272, 6295), prlimit (syscall.tkb:7575,
  the caller itself only) and the spread-timer fixture (process.tkb:6068,
  children only). The handle then comes from
  `scheduled_process_handle_of_slot`, which carries the slot's current
  generation. User space never supplies a generation.
- A path goes to `procfs_lookup` or to ext2 lookup. procfs parses a decimal
  pid and resolves it with `scheduled_process_slot_for_pid_locked`
  (procfs.tkb:108). The procfs render resolves the pid again
  (`scheduled_process_diagnostic_snapshot`, procfs.tkb:319). A stale or
  forged procfs inode number can therefore only name a pid.
- getdents and lseek offsets: a procfs offset decodes to a pid that
  `procfs_next_pid` searches for. An ext2 offset is a byte offset, and the
  directory-block reader bounds it.
- The Takibi-private syscalls 451-453 (syscall.tkb:7854-7999) take the
  caller's own pid (`kernel_process_current_pid`), a phase number, or a
  child pid that goes through the same pid search
  (workload_evidence.tkb:1293, 1403, 1737).

So a generation that user space learned could not be passed in anywhere.

### F3: one monotonic pid counter for the whole system (side channel)

Every process takes its pid from the same `scheduled_process_pid_cell`
(process.tkb:880). Any process can measure the fork rate of the whole
system, either by forking and comparing pids or by reading `/proc` (the
procfs pid list and starttime). Linux behaves the same way without pid
namespaces. This is not a handle leak: pids are never reused here, so a pid
is an identity that never repeats, not a slot. Recommendation: accept it, as
Linux parity. If processes must one day be isolated from each other, the
remedy is pid namespaces or a counter per namespace, not secret generations.

### F4: kernel text addresses visible to user space

`/proc/takibi/profile` prints the irqsoff call sites in hex
(procfs.tkb:292-301, values from `irqsoff_core_site`,
profile_session.tkb:759). The RECORDED irqsoff lines
(profile_session.tkb:735-747) put the same kind of address in the log ring,
which `syslog` returns. Without KASLR these addresses tell an attacker
nothing new, but they would defeat a later KASLR. They are not handles.
Recommendation: when KASLR or the #1032 hardening lands, gate these lines
behind a privilege check or print them as offsets from `_text`.

### F5: `syslog(READ_ALL)` is unprivileged

`syscall_syslog_with` (syscall.tkb:4554-4600) returns the whole log ring to
any process. Nothing here plays the part of Linux's `dmesg_restrict` or
CAP_SYSLOG. A grep of the tree finds slot numbers printed only on fail-stop
paths (`kernel_process_root_authorities_check`, process.tkb:4726-4734, and
`kernel_stack_guard_fail`, process.tkb:7064), after which no user process
runs. Only the stopped-machine debugger (ddb, process.tkb:5571-5577) prints
generations, and it writes straight to the UART (`ddb_puts` ->
`uart_debug_putc`, exception_evidence.tkb:361), not to the ring. Test and
evidence fixtures (`kernel/init/test_driver.tkb:632-708`) print slots and
generations, but only in test images. Nothing leaks today. Still, only
convention keeps slots and generations out of non-fatal log lines.
Recommendation: #709/#710 need no secrecy (see below), so this is
acceptable. The rule should be written down where the log contract lives.

### F6: counters that reveal allocation activity (Linux parity)

These reveal aggregate allocation activity, as their Linux counterparts do:
the statfs free blocks and free inodes (syscall.tkb:1554-1557), resident
pages and starttime in `/proc/<pid>/stat` (procfs.tkb:352-357), sysinfo, and
the counts in `/proc/takibi/profile`. None of them reveals a slot or a
generation. Accept.

### F7: the pid counter has no exhaustion contract

`scheduled_process_mint_pid` (process.tkb:880-886) computes `load + 1` with
no bound check. pids reach user space cut to `u32` (`child_pid as u32` in
siginfo, syscall.tkb:6344), and the Linux `pid_t` is a signed 32-bit
integer. After 2^31 forks, wait4 and clone return values that libc reads as
negative, which it takes for an error, and siginfo no longer agrees with the
wait4 value. That limit is far nearer than 2^64: at 10^4 forks per second it
arrives in about 2.5 days. This is the same shape as #710, a finite identity
counter with no exhaustion branch, but here it sits at the ABI boundary.
Recommendation: fold it into the #710 decision, or file "pid mint: define
exhaustion or recycling within pid_t range". If pids are recycled, they also
need Linux's rule for avoiding quick reuse, and they must not become slots.

### F8: the TCP initial sequence number is a constant

Every connection uses `TCP_INITIAL_SEQ` (kernel/net/tcp.tkb:2835, 3101,
3314). This is about RFC 6528 hardening against off-path injection, not
about handles. It is listed only because the issue asks about predictable
numbers. Recommendation: file it separately if the network stack is ever
used outside the test network.

## Recommendation for #709/#710

1. Generations do not need to be secret, random or keyed. User space can
   neither observe a generation nor pass one in (F1, F2), so guessing one
   gains nothing. #709/#710 can keep a plain monotonic counter.
2. Exhaustion is the only real question, and user space cannot force it
   quickly. Only syscalls allocate or free slots, at most a few per call, so
   reaching 2^64 is infeasible. Refusing at allocation (a closed `Exhausted`
   outcome, or a fail-stop) therefore exposes nothing new. Choose that
   design because it is simple and testable, not as a defence. The one
   identity counter that user space can exhaust in practice is the pid
   (F7), and at the ABI it is 32 bits wide.
3. Make the boundary invariant explicit. Today it holds because this review
   found it, not because a check enforces it. The cheapest guard is a build
   check (rung 3): fail when a value read from a `.generation` field or a
   handle accessor reaches `user_write_*`, `copy_to_user*` or
   `SyscallAction::Resume` in `kernel/kernel/syscall.tkb`. The type-level
   guard (rung 1) would be an opaque `Generation` type that only the pool
   templates may cast with `as usize`. That is bigger than #709/#710, so it
   is proposed as a follow-up, not a precondition.
