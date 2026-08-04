# Syscall support matrix

Every syscall number `kernel_syscall_dispatch` (`kernel/kernel/syscall.tkb`)
recognizes, what it actually does, and why. Anything not listed here falls
through to the final `return (1, LINUX_ENOSYS);` and is Unsupported by
design -- issue #175 exists specifically so that state is documented rather
than silently true.

Reached-by-BusyBox column reflects the real, traced integration this kernel
runs: pinned Alpine `busybox-static`/`busybox-extras` 1.37.0-r31 (ash +
`httpd -f -p 8080 -h /`) dynamically linked against pinned `musl` 1.2.6-r2
(see `Makefile`'s `KERNEL_BUSYBOX_URL`/`KERNEL_HTTPD_URL`/`KERNEL_MUSL_URL`).

| # | name | status | notes |
|---|------|--------|-------|
| 17 | getcwd | Implemented | this kernel has exactly one real directory (`/`); always returns it. Returns the real byte count written (matching the raw syscall's own contract, distinct from the POSIX library wrapper's buffer-pointer return) -- previously returned the buffer address instead, never caught because no scenario called it before issue #196's `sh -c` scenario did |
| 24 | dup3 | Implemented | accepted-fd -> stdin/stdout aliasing only, matching the traced daemon child's own shape |
| 49 | chdir | Implemented | succeeds only for `/` (`ENOENT` otherwise) -- honest, since the one real cwd never actually changes |
| 56 | openat | Implemented | generic NUL-terminated single-component absolute/relative root lookup against the USB ext2 mount; `dirfd` ignored |
| 57 | close | Implemented | |
| 63 | read | Implemented | connected-socket, ext2-file, and UART-fallback paths, all through the issue #174 user-memory boundary |
| 64 | write | Implemented | same three paths as `read`, plus the inetd-response path |
| 65 | readv | Partial | fd 3 (ext2 file) only, via a standalone segment helper not shared with `read`(64)'s TCP/inetd branches. Each iovec entry validated and copied individually through the #174/#196 boundary (`struct packed Iovec`, `IOV_MAX`-bounded, `checked_mul_usize`/`checked_add_usize`-guarded array-length and running-total arithmetic). Connected-TCP/inetd fd support tracked in #204 |
| 66 | writev | Partial | fd 1/2 (UART) only -- same scoping and #204 note as `readv` above |
| 71 | sendfile | Implemented | fd 3 (ext2 file) -> fd 1/2 (UART) only, offset must be 0 |
| 73 | ppoll | Partial | real pollfd array validation (`struct packed Pollfd`, `POLL_MAX`-bounded) and real per-fd readiness (UART RX pending, connected-TCP buffered data) -- but never actually blocks regardless of the caller's timeout. Real blocking semantics tracked in #205 |
| 79 | newfstatat | Implemented | generic single-component root lookup plus fixed asm-generic AArch64 `stat` fields for ext2 regular files |
| 93/94 | exit/exit_group | Implemented | real child-vs-parent teardown via the process/fd/VM-clone machinery |
| 96 | set_tid_address | Implemented | returns the real current pid (single-threaded-per-process model) |
| 103 | setitimer | Partial | previous timer is honestly zeroed; no real itimer is armed (this kernel's bounded single-request integration scope never needs `SIGALRM` to actually fire) |
| 113 | clock_gettime | Implemented | fixed epoch-ish timestamp; sufficient for BusyBox httpd's own use |
| 134 | rt_sigaction | Partial | `signum` validated (`EINVAL` for 0/`SIGKILL`/`SIGSTOP`); non-null `oldact` is validated and zero-filled via the #174 boundary instead of left uninitialized; no real signal delivery exists, so an installed handler is never actually invoked (see issue #175's own audit for why this is safe against the real traced calls: `signal(SIGPIPE\|SIGALRM\|SIGCHLD\|SIGHUP, ...)`, none of which check the return value) |
| 135 | rt_sigprocmask | Implemented | previous mask is honestly zeroed |
| 160 | uname | Implemented | real `struct utsname` reply via the #174/#196 boundary (`sysname="Linux"`, `nodename="takibi"`, `release="6.1.0-takibi"`, `version="#1"`, `machine="aarch64"`), zero-filled scratch buffer first so no uninitialized kernel memory reaches userspace |
| 172 | getpid | Implemented | |
| 173 | getppid | Implemented | returns 0 (single-process-tree-root model) |
| 174-177 | getuid/geteuid/getgid/getegid | Implemented | return 0 (always-root model) |
| 178 | gettid | Implemented | returns the real current pid |
| 198 | socket | Implemented | `AF_INET`/`AF_INET6`, `SOCK_STREAM` only |
| 200 | bind | Implemented | IPv4/IPv6 sockaddr validated through the #174 boundary |
| 201 | listen | Implemented | |
| 202/242 | accept/accept4 | Implemented | holds the sole physical RX capability across the blocking handshake |
| 205 | getpeername | Implemented | fixed `AF_INET` reply (single-peer-per-connection model) |
| 208 | setsockopt | Partial | `optval`/`optlen` validated through the #174 boundary when `optlen != 0`; no `level`/`optname` is actually honored, but none is meaningfully actionable in this kernel's single-listener-per-port/single-connection model either (the two real calls reached, `SO_REUSEADDR` on the listener and `SO_KEEPALIVE` on each accepted connection, are both genuinely no-ops here) |
| 210 | shutdown | Implemented | `SHUT_WR` on fd 1, both direct and inetd response modes |
| 214 | brk | Implemented | real heap-break growth within the fixed process arena |
| 215 | munmap | Unsupported-by-design | the fixed short-lived process arena is reclaimed as a unit; not reachable in practice (musl never calls `munmap` in this integration) |
| 220 | clone | Implemented | `CLONE_VM\|CLONE_VFORK` shape only, matching BusyBox httpd's own observed fork usage |
| 221 | execve | Partial | parent handoff plus child-frame replacement for the registered static BusyBox image; copies pathname/argv, builds root-1 child image state, and returns child exit through the saved parent frame |
| 260 | wait4 | Partial | retrieves the completed one-child clone status once; blocking multi-child wait/reap remains deferred |
| 222 | mmap | Partial | anonymous-only (`MAP_PRIVATE\|MAP_ANONYMOUS`, `fd=-1`, no `PROT_EXEC`) via a heap-break-cursor emulation, not a real independent mapping; every real call shape musl's mallocng makes satisfies this (verified against pinned musl 1.2.6 source, see issue #175) |
| 226 | mprotect | Partial | real permission changes for exactly one transition (`RW+XN` <-> `R+XN` on data/heap/stack, issue #174); anything else (adding `PROT_EXEC`, targeting text/rodata, mixed-class ranges) returns a real `EACCES`/`EINVAL`, never false success |
| 451 | (Takibi-internal) UART RX wait | Implemented | not a real Linux syscall number; this kernel's own blocking-UART-RX primitive |
| 452 | (Takibi-internal) parent progress | Implemented | not a real Linux syscall number; concurrency-proof instrumentation only |

## Syscalls confirmed correctly Unsupported-by-design

These are named in issue #175's original problem list (written against the
older `examples/el0_shell` fixture) but are simply not implemented in
`kernel/`, so they already return `LINUX_ENOSYS` -- confirmed intentional,
not an oversight:

| # | name |
|---|------|
| 25 | fcntl |
| 68 | pwrite64 |
| 167 | prctl |
| 278 | getrandom |
| 293 | rseq |

## Maintenance note

When a new syscall arm is added, add its row here in the same commit,
classify it Implemented/Partial/Unsupported-by-design, and -- per issue
#175's policy -- do not copy a false-success shortcut from `examples/
el0_shell` into this file's Implemented/Partial rows without a real reason
documented alongside it.
