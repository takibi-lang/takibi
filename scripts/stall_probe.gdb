# GitHub issue #665: print the race-window kernels' stall probes
# (kernel/kernel/stall_probe.tkb) from the failure capture's GDB, before the
# serial BREAK. Raw words: the arrays carry no debug type. Times are
# CNTPCT_EL0 counts; compare them with each other, not with wall time.
printf "stall_probe: begin\n"
printf "stall_probe: last_tick\n"
x/4gu &stall_probe_last_tick
printf "stall_probe: idle_passes\n"
x/4gu &stall_probe_idle_passes
printf "stall_probe: last_idle_pass\n"
x/4gu &stall_probe_last_idle_pass
printf "stall_probe: last_wfi\n"
x/4gu &stall_probe_last_wfi
printf "stall_probe: last_resume\n"
x/4gu &stall_probe_last_resume
printf "stall_probe: refusals\n"
x/4gu &stall_probe_refusals
printf "stall_probe: last_refused_pid\n"
x/4gu &stall_probe_last_refused_pid
printf "stall_probe: tick_count\n"
x/4gu &secondary_tick_count
printf "stall_probe: watch (parent, reader)\n"
x/2gu &stall_probe_watch
printf "stall_probe: next\n"
x/1gu &stall_probe_next
printf "stall_probe: event_pid\n"
x/32gu &stall_probe_event_pid
printf "stall_probe: event_kind (1 block, 2 wake, 3 start, 4 yield)\n"
x/32gu &stall_probe_event_kind
printf "stall_probe: event_cpu\n"
x/32gu &stall_probe_event_cpu
printf "stall_probe: event_time\n"
x/32gu &stall_probe_event_time
printf "stall_probe: end\n"
