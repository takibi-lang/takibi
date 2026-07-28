# EL0 shell compatibility scope

This example is a BusyBox bring-up and regression fixture. It is not the
syscall contract for the production kernel planned in GitHub issue #177.

The table below classifies every syscall arm in `el0_shell.tkb`. "Narrow"
means that the implementation is useful for the fixture but intentionally
does not implement general Linux semantics. "False success" means that the
arm reports success without implementing an observable contract and must not
be copied into `kernel/`.

| AArch64 number | Syscall | Status | Fixture contract |
| --- | --- | --- | --- |
| 17 | getcwd | Narrow | Always returns `/`. |
| 24 | dup3 | Narrow | Supports redirection onto fd 0 only. |
| 25 | fcntl | False success | Emulates the shell's fd-save pattern without general fd state. |
| 29 | ioctl | Narrow | Always returns `-ENOTTY`. |
| 49 | chdir | False success | Returns success without changing kernel cwd state. |
| 56 | openat | Narrow | FAT12 root, 8.3 names, read or create/truncate only. |
| 57 | close | Narrow | Closes tracked FAT files; accepts fixture pseudo-fds. |
| 63 | read | Narrow | UART stdin or sequential FAT12 file reads. |
| 64 | write | Narrow | UART stdout/stderr or sequential FAT12 file writes. |
| 66 | writev | Narrow | UART stdout/stderr only. |
| 68 | pwrite64 | False success | Shares sequential write and ignores the offset. |
| 73 | ppoll | Narrow | Reports only fd 0 readiness. |
| 79 | newfstatat | Narrow | UART-like empty-path stat or FAT12 root-file stat. |
| 93, 94 | exit, exit_group | Narrow | Single parent and one cooperative child. |
| 96 | set_tid_address | False success | Returns fixed TID 1 without registration. |
| 99 | set_robust_list | False success | Records no robust-list state. |
| 134 | rt_sigaction | False success | Installs no signal action. |
| 135 | rt_sigprocmask | False success | Maintains no signal mask. |
| 160 | uname | Narrow | Returns a fixed Linux-compatible identity. |
| 167 | prctl | False success | Applies no requested operation. |
| 172-178 | identity queries | Narrow | Fixed single-process/root identity values. |
| 214 | brk | Narrow | Bump allocation inside a fixed pre-mapped heap. |
| 220 | clone | Narrow | One cooperative fork-shaped child only. |
| 221 | execve | Narrow | FAT12 root file, fixed argv, child only. |
| 222 | mmap | False success | Treats every request as anonymous RWX heap memory. |
| 226 | mprotect | False success | Changes no page permissions. |
| 260 | wait4 | Narrow | Reaps the one already-completed child. |
| 278 | getrandom | False success | Writes a predictable test pattern, not entropy. |
| 293 | rseq | False success | Registers no restartable sequence state. |
| other | unsupported | Fail-stop | Falls into the exception-unhandled path. |

The production kernel rules are stricter:

- Implement a small syscall subset with correct observable semantics.
- Decode unsupported syscall numbers to `-ENOSYS` rather than false success
  or an exception hang.
- Keep raw Linux integer and `-errno` encoding at the trap boundary; internal
  fallible operations return named variants.
- Never copy a "False success" arm above into `kernel/`.
- Add success and failure tests when each syscall enters the supported set.

GitHub issues #174 and #175 track the user-memory and syscall-contract work.
