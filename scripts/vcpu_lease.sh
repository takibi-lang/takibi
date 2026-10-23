#!/usr/bin/env bash
# The host-wide QEMU vCPU budget. Bash only, and kept out of resource_lease.sh
# because that file is also sourced by /bin/sh: allcheck's recipe sources it,
# and one bash-only construct anywhere in it stops the dash parse of the whole
# file before allcheck starts.
. "$(dirname "${BASH_SOURCE[0]}")/resource_lease.sh"

# -- vCPU budget (GitHub issue #719) ------------------------------------------
# A QEMU guest is as many host threads as its `-smp`, and #509 measured that
# host starvation, not the lane count, is what stalls a guest mid-boot. So
# each runner leases as many vCPUs as the guest it starts, from a budget of
# host cores (TAKIBI_QEMU_VCPU_BUDGET overrides it), before it starts any
# timing. A lane that would exceed the budget waits rather than starting.
#
# One slot is one flock file, so the budget holds across every container that
# mounts the registry, exactly as the leases above do. A runner takes all of
# its slots under one allocation lock: two runners that each took part of what
# they need could otherwise wait on each other forever. The holder of the
# allocation lock waits only on slots held by runners that already have all
# of theirs, and those finish without it.
#
# The slots are inherited descriptors of the runner, so a QEMU the runner
# starts from bash holds them too and a leftover guest keeps its vCPUs until
# it really exits. Python's subprocess closes them in the child, which is why
# scripts/qemu.sh looks for the lease on its ancestors rather than on itself.
#
# TAKIBI_QEMU_SMP is the one setting every runner's `-smp` comes from.
TAKIBI_QEMU_SMP="${TAKIBI_QEMU_SMP:-4}"
export TAKIBI_QEMU_SMP

# The cores a guest of TAKIBI_QEMU_SMP vCPUs brings online: the kernel admits
# at most KERNEL_MAX_CORES (4, kernel/lib/execution_model.tkb). Runners derive
# their expectations from these instead of spelling out a core count.
qemu_online_core_count() {
    local n="$TAKIBI_QEMU_SMP"
    if [ "$n" -gt 4 ]; then n=4; fi
    printf '%s\n' "$n"
}

# "0,1,...,n-1"
qemu_online_cpus_csv() {
    local n i out=""
    n="$(qemu_online_core_count)"
    for ((i = 0; i < n; i++)); do out="${out:+$out,}$i"; done
    printf '%s\n' "$out"
}

# The mask, in hex without 0x, of every online core except core $1: what the
# kernel's `oops: world-stop complete mask=0x...` line names.
qemu_online_mask_without() {
    local n
    n="$(qemu_online_core_count)"
    printf '%x\n' $(( ((1 << n) - 1) & ~(1 << $1) ))
}

resource_lease_vcpu_dir() {
    printf '%s/vcpu\n' "$(resource_lease_dir)"
}

resource_lease_vcpu_budget() {
    printf '%s\n' "${TAKIBI_QEMU_VCPU_BUDGET:-$(nproc)}"
}

# How many vCPU slots PID holds, by its open descriptors.
resource_lease_vcpu_held_by() {
    local pid="$1" dir fd target n=0
    dir="$(readlink -f "$(resource_lease_vcpu_dir)" 2>/dev/null)" || { echo 0; return 0; }
    for fd in /proc/"$pid"/fd/*; do
        target="$(readlink "$fd" 2>/dev/null)" || continue
        case "$target" in "$dir"/slot.*.lock) n=$((n + 1));; esac
    done
    echo "$n"
}

# How many slots this process or its nearest holding ancestor has. Pids are
# only asked about inside this pid namespace, along this process's own parent
# chain, so the caveat about other containers' pids above does not apply.
resource_lease_vcpu_held() {
    local pid="${1:-$$}" n
    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
        n="$(resource_lease_vcpu_held_by "$pid")"
        if [ "$n" -gt 0 ]; then
            echo "$n"
            return 0
        fi
        pid="$(awk '{ print $4 }' "/proc/$pid/stat" 2>/dev/null)" || break
    done
    echo 0
}

resource_lease_vcpu_holders() {
    local dir file
    dir="$(resource_lease_vcpu_dir)"
    shopt -s nullglob
    for file in "$dir"/slot.*.holder; do
        if ! (exec 6>"${file%.holder}.lock" && flock -n 6) 2>/dev/null; then
            printf '%s %s\n' "$(resource_lease_field "$file" session)" \
                "$(resource_lease_field "$file" target)"
        fi
    done | sort | uniq -c | awk '{ n = $1; $1 = ""; printf "%s%s x%d", sep, substr($0, 2), n; sep = ", " }'
    shopt -u nullglob
}

# GitHub issue #914: the race-window lanes spent their extra allcheck time
# waiting here before boot, and nothing recorded how long. When the run has a
# lane-timing directory, every acquire that has to take slots appends one
# JSON line -- lane, vCPUs, when the wait began and when the slots were
# granted (null when it timed out) -- to vcpu-lease.waits there. The suffix is
# not .jsonl on purpose: scripts/summarize_lane_timing.py reads every .jsonl
# as a finished lane, and reports these separately.
resource_lease_vcpu_record_wait() {
    local want="$1" target="$2" began="$3" granted="$4" lane
    [ -n "${TAKIBI_LANE_TIMING_DIR:-}" ] || return 0
    mkdir -p "$TAKIBI_LANE_TIMING_DIR" 2>/dev/null || return 0
    lane="${TAKIBI_AWAIT_TIMING_LANE:-$target}"
    lane="$(printf '%s' "$lane" | tr -d '"\\')"
    printf '{"lane":"%s","vcpus":%s,"wait_start":%s,"granted":%s}\n' \
        "$lane" "$want" "$began" "$granted" \
        >>"$TAKIBI_LANE_TIMING_DIR/vcpu-lease.waits" 2>/dev/null || true
}

# -- Grant order (GitHub issue #927) -----------------------------------------
# Without an order, the slots went to whichever waiter flock woke first. One
# allcheck then waited about 4350 s in total for vCPUs, and the longest lane
# (probe-ticks, three guests in a row) queued again behind every fresh lane
# before each of its guests, so it finished last and alone. A waiter now
# takes a ticket and only the first live ticket may go for the slots. The
# order is: the earlier run first (so a second allcheck on the host cannot
# overtake the first), then the lane's rank in TAKIBI_VCPU_LANE_ORDER, a
# longest-lane-first list, then the earlier wait. Longest-first is the
# classic list-scheduling rule for a span: the long lanes start at once and
# the short ones fill the gaps around them. A lane missing from the list
# ranks after every listed one, so a new lane is never wrong, only unordered.
#
# The order is by each lane's time holding vCPUs -- its duration less its
# lease wait, both printed by scripts/summarize_lane_timing.py -- measured on
# the QEMU lanes 2026-10-23. A stale order costs span, never a verdict.
TAKIBI_VCPU_LANE_ORDER="${TAKIBI_VCPU_LANE_ORDER:-kernelcheck-probe-ticks-qemu
kernelcheck-race-window-705-qemu kernelcheck-race-window-603-qemu
kernelcheck-qemu-main kernelcheck-race-window-609-qemu
kernelcheck-race-window-633-qemu kernelcheck-race-window-678-qemu
kernelcheck-uart-wake-qemu kernelcheck-alloc-rollback-qemu
kernelcheck-race-window-635-qemu kernelcheck-race-window-830-qemu
kernelcheck-qemu-debug-main kernelcheck-affinity-gdb-qemu
kernelcheck-oops-qemu kernelcheck-race-window-761-qemu kernelcheck-ddb-qemu}"

# The ticket's name sorts into grant order.
resource_lease_vcpu_ticket_key() {
    local began="$1" lane="${TAKIBI_AWAIT_TIMING_LANE:-}" origin="" rank=999 i=0 name
    if [ -n "${TAKIBI_LANE_TIMING_DIR:-}" ] && [ -f "$TAKIBI_LANE_TIMING_DIR/run.origin" ]; then
        origin="$(head -n 1 "$TAKIBI_LANE_TIMING_DIR/run.origin" 2>/dev/null)"
    fi
    case "$origin" in ''|*[!0-9.]*) origin="$began";; esac
    if [ -n "$lane" ]; then
        for name in $TAKIBI_VCPU_LANE_ORDER; do
            if [ "$name" = "$lane" ]; then rank="$i"; break; fi
            i=$((i + 1))
        done
    fi
    printf '%010d-%03d-%s-%s\n' "${origin%.*}" "$rank" "$began" "$$"
}

RESOURCE_LEASE_VCPU_TICKET_FD=""
RESOURCE_LEASE_VCPU_TICKET=""

resource_lease_vcpu_ticket_drop() {
    [ -n "$RESOURCE_LEASE_VCPU_TICKET" ] && rm -f "$RESOURCE_LEASE_VCPU_TICKET"
    [ -n "$RESOURCE_LEASE_VCPU_TICKET_FD" ] && exec {RESOURCE_LEASE_VCPU_TICKET_FD}>&-
    RESOURCE_LEASE_VCPU_TICKET_FD=""
    RESOURCE_LEASE_VCPU_TICKET=""
}

# The first ticket whose owner still holds its lock. A ticket nobody holds
# was left by a runner that died, and is removed. The owner locks its ticket
# under a temporary name and renames it into place, so no live ticket is ever
# seen unlocked.
resource_lease_vcpu_queue_head() {
    local queue="$1" file probe
    shopt -s nullglob
    for file in "$queue"/*.ticket; do
        [ "$file" = "$RESOURCE_LEASE_VCPU_TICKET" ] && { printf '%s\n' "$file"; break; }
        exec {probe}<"$file" 2>/dev/null || continue
        if flock -n "$probe"; then
            rm -f "$file"
            exec {probe}<&-
            continue
        fi
        exec {probe}<&-
        printf '%s\n' "$file"
        break
    done
    shopt -u nullglob
}

# resource_lease_vcpu_ticket_take DIR TARGET -- queue this runner; the
# caller drops the ticket once it has its slots or gives up.
resource_lease_vcpu_ticket_take() {
    local dir="$1" target="$2" queue key tmp
    queue="$dir/queue"
    mkdir -p "$queue"
    key="$(resource_lease_vcpu_ticket_key "$(date +%s.%3N)")"
    tmp="$queue/.$key.tmp"
    exec {RESOURCE_LEASE_VCPU_TICKET_FD}>"$tmp"
    flock -n "$RESOURCE_LEASE_VCPU_TICKET_FD"
    printf 'target=%s\nsession=%s\n' "$target" "${TAKIBI_SESSION:-unknown}" >"$tmp"
    RESOURCE_LEASE_VCPU_TICKET="$queue/$key.ticket"
    mv "$tmp" "$RESOURCE_LEASE_VCPU_TICKET"
}

# resource_lease_vcpu_queue_wait DIR DEADLINE -- return once this runner's
# ticket is the first live one; nonzero at the deadline.
resource_lease_vcpu_queue_wait() {
    local queue="$1/queue" deadline="$2" announced=0
    while [ "$(resource_lease_vcpu_queue_head "$queue")" != "$RESOURCE_LEASE_VCPU_TICKET" ]; do
        if [ "$announced" -eq 0 ]; then
            echo "[lease] queued for vCPUs behind earlier or longer lanes" >&2
            announced=1
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "FAIL resource-lease: still queued for vCPUs after ${RESOURCE_LEASE_TIMEOUT_SECONDS}s" >&2
            return 1
        fi
        sleep 0.5
    done
}

# resource_lease_vcpu_acquire N [TARGET] -- hold N slots in this shell.
resource_lease_vcpu_acquire() {
    local want="$1" target="${2:-$0}"
    local have budget dir alloc fd need i deadline announced=0 began
    local -a held

    case "$want" in ''|*[!0-9]*|0) echo "error: vCPU lease needs a positive count, got '$want'" >&2; return 1;; esac
    have="$(resource_lease_vcpu_held)"
    [ "$have" -ge "$want" ] && return 0
    budget="$(resource_lease_vcpu_budget)"
    if [ "$want" -gt "$budget" ]; then
        echo "error: a guest of $want vCPUs can never fit the budget of $budget" >&2
        return 1
    fi

    began="$(date +%s.%3N)"
    dir="$(resource_lease_vcpu_dir)"
    mkdir -p "$dir"
    resource_lease_vcpu_ticket_take "$dir" "$target"
    deadline=$((SECONDS + RESOURCE_LEASE_TIMEOUT_SECONDS))
    while :; do
        resource_lease_vcpu_queue_wait "$dir" "$deadline" || {
            resource_lease_vcpu_ticket_drop
            resource_lease_vcpu_record_wait "$want" "$target" "$began" null
            return 1
        }
        exec {alloc}>"$dir/alloc.lock"
        if ! flock -n "$alloc"; then
            echo "[lease] waiting for the vCPU allocator (another runner is waiting for slots)" >&2
            announced=1
            if ! flock -w "$RESOURCE_LEASE_TIMEOUT_SECONDS" "$alloc"; then
                echo "FAIL resource-lease: the vCPU allocator was still held after ${RESOURCE_LEASE_TIMEOUT_SECONDS}s" >&2
                exec {alloc}>&-
                resource_lease_vcpu_ticket_drop
                resource_lease_vcpu_record_wait "$want" "$target" "$began" null
                return 1
            fi
        fi

        need="$want"
        held=()
        while :; do
            for ((i = 0; i < budget && need > 0; i++)); do
                exec {fd}>"$dir/slot.$i.lock"
                if flock -n "$fd"; then
                    resource_lease_write "$dir/slot.$i.holder" \
                        "session=${TAKIBI_SESSION:-unknown}" \
                        "target=$target" \
                        "pid=$$" \
                        "started=$(date +%H:%M:%S)"
                    held+=("$fd")
                    need=$((need - 1))
                else
                    exec {fd}>&-
                fi
            done
            [ "$need" -eq 0 ] && break 2
            if [ "$announced" -eq 0 ]; then
                echo "[lease] waiting for $need more of $want vCPUs (budget $budget):" \
                     "$(resource_lease_vcpu_holders)" >&2
                announced=1
            fi
            if [ "$SECONDS" -ge "$deadline" ]; then
                echo "FAIL resource-lease: $want vCPUs were not free after" \
                     "${RESOURCE_LEASE_TIMEOUT_SECONDS}s: $(resource_lease_vcpu_holders)" >&2
                for fd in "${held[@]}"; do exec {fd}>&-; done
                exec {alloc}>&-
                resource_lease_vcpu_ticket_drop
                resource_lease_vcpu_record_wait "$want" "$target" "$began" null
                return 1
            fi
            sleep 0.5
            # A longer lane queued behind this one while it waited (#927):
            # give back the partial hold and the allocator, and queue again.
            if [ "$(resource_lease_vcpu_queue_head "$dir/queue")" != "$RESOURCE_LEASE_VCPU_TICKET" ]; then
                for fd in "${held[@]}"; do exec {fd}>&-; done
                exec {alloc}>&-
                continue 2
            fi
        done
    done
    exec {alloc}>&-
    resource_lease_vcpu_ticket_drop
    resource_lease_vcpu_record_wait "$want" "$target" "$began" "$(date +%s.%3N)"
    [ "$announced" -eq 0 ] || echo "[lease] got $want vCPUs" >&2
}

resource_lease_vcpu_status() {
    local dir budget file busy=0
    dir="$(resource_lease_vcpu_dir)"
    budget="$(resource_lease_vcpu_budget)"
    shopt -s nullglob
    for file in "$dir"/slot.*.lock; do
        (exec 6>"$file" && flock -n 6) 2>/dev/null || busy=$((busy + 1))
    done
    shopt -u nullglob
    printf '%-8s %d of %d held%s\n' vcpu "$busy" "$budget" \
        "$([ "$busy" -eq 0 ] || printf ': %s' "$(resource_lease_vcpu_holders)")"
}
