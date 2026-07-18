#!/usr/bin/env bash
# Profiles examples/kvs_server_sdcard_rtos on real STM32 hardware.
#
# Unlike profile_stm32_http_server_sdcard_rtos.sh (which profiles a GET of
# a static file from SD), this profiles a PUT -- the write-through save
# path -- since that's the operation GitHub issue #135's stress-test
# findings measured at ~92ms p50 and want a cycle-level breakdown of
# (KVS table update, HTTP/TCP framing, RTOS rendezvous with sd_worker,
# FAT12 file write, real SD card I/O). The measured PUT overwrites the
# SAME key the warm-up PUT already created, so it exercises the ordinary
# overwrite path (matching what every previous measurement in this issue
# used), not first-ever-creation or table-full edge cases.
#
# No SD card provisioning step: unlike http_server_sdcard(_rtos), this
# firmware does not need a pre-seeded FAT12 image -- it self-formats an
# unrecognized card and creates its own table file on first save (see
# kvs_server_sdcard_rtos.tkb's header comment).
#
# The firmware is built with takibi --profile-functions, loaded into AXI
# SRAM1, exercised by either a single host curl PUT (default) or
# scripts/kvs_stress.py (TAKIBI_PROFILE_LOAD=stress), then halted so OpenOCD
# can dump __takibi_prof_table from RAM. The table format is fixed by
# lib/llvm_gen.ml:
#   struct Entry { u32 id; u32 calls; u64 inclusive_cycles; }
set -euo pipefail

: "${STM32_SERIAL_DEV:?STM32_SERIAL_DEV is required; run through make or set it explicitly}"

OPENOCD_BOARD_CFG="board/stm32f746g-disco.cfg"
ELF="examples/kvs_server_sdcard_rtos/kernel_stm32_ram.prof.elf"
OBJ="examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos_stm32.prof.o"
KEY="profkey"
URL="${TAKIBI_PROFILE_URL:-http://192.168.10.2/keys/$KEY}"
PUT_BODY="${TAKIBI_PROFILE_PUT_BODY:-takibi profile probe value}"
OUT_DIR="${TAKIBI_PROFILE_OUT_DIR:-_build/takibi_profile/kvs_server_sdcard_rtos}"
PROFILE_LOAD="${TAKIBI_PROFILE_LOAD:-single}"
STRESS_CONCURRENCY="${TAKIBI_PROFILE_STRESS_CONCURRENCY:-24}"
STRESS_DURATION="${TAKIBI_PROFILE_STRESS_DURATION:-30}"
STRESS_VALUE_SIZE="${TAKIBI_PROFILE_STRESS_VALUE_SIZE:-64}"
STRESS_TIMEOUT="${TAKIBI_PROFILE_STRESS_TIMEOUT:-5}"
PATH_ENTRY_SIZE=84
PATH_ENTRY_COUNT=256

# shellcheck source=scripts/stm32_hw_claim.sh
source "$(dirname "$0")/stm32_hw_claim.sh"
claim_stm32_hardware "$STM32_SERIAL_DEV"

tmpdir=$(mktemp -d)
mkdir -p "$OUT_DIR"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

ram_load_and_run() {
    local elf="$1" log
    log="$tmpdir/openocd-load.log"
    openocd -f "$OPENOCD_BOARD_CFG" \
        -c "init" \
        -c "reset halt" \
        -c "load_image $elf 0 elf" \
        -c "set vec0 [mrw 0x20010000]" \
        -c "set vec1 [mrw 0x20010004]" \
        -c "set pcval [expr {\$vec1 & ~1}]" \
        -c "reg sp \$vec0" \
        -c "reg pc \$pcval" \
        -c "resume" \
        -c "shutdown" > "$log" 2>&1 || {
            echo "openocd RAM load failed:" >&2
            sed 's/^/       /' "$log" >&2
            return 1
        }
}

dump_profile_table() {
    local addr="$1" size="$2" out="$3" log
    log="$tmpdir/openocd-dump.log"
    openocd -f "$OPENOCD_BOARD_CFG" \
        -c "init" \
        -c "halt" \
        -c "dump_image $out $addr $size" \
        -c "shutdown" > "$log" 2>&1 || {
            echo "openocd profile dump failed:" >&2
            sed 's/^/       /' "$log" >&2
            return 1
        }
}

clear_profile_counters_and_resume() {
    local table_addr="$1" count="$2" path_addr="$3" path_size="$4" log
    log="$tmpdir/openocd-clear.log"
    openocd -f "$OPENOCD_BOARD_CFG" \
        -c "init" \
        -c "halt" \
        -c "set prof_base $table_addr" \
        -c "set prof_count $count" \
        -c 'for {set i 0} {$i < $prof_count} {incr i} {
                set entry [expr {$prof_base + ($i * 16)}]
                mww [expr {$entry + 4}] 0
                mww [expr {$entry + 8}] 0
                mww [expr {$entry + 12}] 0
            }' \
        -c "set path_base $path_addr" \
        -c "set path_words [expr {$path_size / 4}]" \
        -c 'for {set i 0} {$i < $path_words} {incr i} {
                mww [expr {$path_base + ($i * 4)}] 0
            }' \
        -c "resume" \
        -c "shutdown" > "$log" 2>&1 || {
            echo "openocd profile clear failed:" >&2
            sed 's/^/       /' "$log" >&2
            return 1
        }
}

put_key() {
    local label="$1"
    local curl_ok=0
    echo "PUT $URL ($label) ..."
    for attempt in $(seq 1 "${TAKIBI_PROFILE_CURL_ATTEMPTS:-10}"); do
        if curl --fail --silent --show-error --max-time "${TAKIBI_PROFILE_CURL_TIMEOUT:-90}" \
            -X PUT --data-binary "$PUT_BODY" "$URL" > "$tmpdir/put-$label.out"; then
            curl_ok=1
            break
        fi
        echo "PUT $label attempt $attempt failed; retrying..." >&2
        sleep 1
    done
    if [ "$curl_ok" -ne 1 ]; then
        echo "PUT $label failed after ${TAKIBI_PROFILE_CURL_ATTEMPTS:-10} attempts" >&2
        exit 1
    fi
}

run_stress_load() {
    echo "Running kvs_stress.py (concurrency=$STRESS_CONCURRENCY duration=${STRESS_DURATION}s) ..."
    python3 scripts/kvs_stress.py \
        --host 192.168.10.2 \
        --port 80 \
        --concurrency "$STRESS_CONCURRENCY" \
        --duration "$STRESS_DURATION" \
        --value-size "$STRESS_VALUE_SIZE" \
        --timeout "$STRESS_TIMEOUT" | tee "$OUT_DIR/stress.txt"
}

echo "Loading profiled KVS+SD+RTOS firmware..."
ram_load_and_run "$ELF"

table_addr=$(llvm-nm-19 "$ELF" | awk '$3 == "__takibi_prof_table" { print "0x" $1; exit }')
if [ -z "$table_addr" ]; then
    echo "could not find __takibi_prof_table in $ELF" >&2
    exit 1
fi
path_addr=$(llvm-nm-19 "$ELF" | awk '$3 == "__takibi_prof_path_table" { print "0x" $1; exit }')
if [ -z "$path_addr" ]; then
    echo "could not find __takibi_prof_path_table in $ELF" >&2
    exit 1
fi

profile_count=$(python3 - "$OBJ" <<'PY'
import subprocess
import sys

obj = sys.argv[1]
out = subprocess.check_output(["llvm-nm-19", obj], text=True)
names = []
for line in out.splitlines():
    parts = line.split()
    if len(parts) >= 3 and parts[1] == "T":
        name = parts[2]
        if name == "pendsv_dispatch" or name.endswith("Handler") or name.startswith("__takibi_prof_"):
            continue
        names.append(name)
print(len(sorted(names)))
PY
)
table_size=$((profile_count * 16))
path_size=$((PATH_ENTRY_COUNT * PATH_ENTRY_SIZE))
dump="$tmpdir/takibi_prof_table.bin"
path_dump="$tmpdir/takibi_prof_path_table.bin"

# Warm-up PUT creates the key (net_init/disk_initialize/ARP/PHY settling
# all happen here, same reasoning as the http_server_sdcard_rtos script's
# "warm" fetch) -- not measured.
put_key "warm"

echo "Clearing profile counters after warm-up..."
clear_profile_counters_and_resume "$table_addr" "$profile_count" "$path_addr" "$path_size"

case "$PROFILE_LOAD" in
    single)
        # Measured PUT overwrites the same key -- the ordinary write-through
        # overwrite path every other measurement in issue #135 used.
        put_key "measured"
        profile_title="PUT overwrite"
        ;;
    stress)
        run_stress_load
        profile_title="kvs_stress concurrency=$STRESS_CONCURRENCY duration=${STRESS_DURATION}s"
        ;;
    *)
        echo "unknown TAKIBI_PROFILE_LOAD=$PROFILE_LOAD (expected single or stress)" >&2
        exit 1
        ;;
esac

echo "Dumping $profile_count profile entries from $table_addr ..."
dump_profile_table "$table_addr" "$table_size" "$dump"
echo "Dumping $PATH_ENTRY_COUNT call-path entries from $path_addr ..."
dump_profile_table "$path_addr" "$path_size" "$path_dump"

python3 - "$OBJ" "$dump" "$path_dump" "$OUT_DIR/profile.folded" "$profile_title" <<'PY'
import struct
import subprocess
import sys

obj, dump, path_dump, folded_out, profile_title = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
out = subprocess.check_output(["llvm-nm-19", obj], text=True)
names = []
for line in out.splitlines():
    parts = line.split()
    if len(parts) >= 3 and parts[1] == "T":
        name = parts[2]
        if name == "pendsv_dispatch" or name.endswith("Handler") or name.startswith("__takibi_prof_"):
            continue
        names.append(name)
names = sorted(names)

rows = []
with open(dump, "rb") as f:
    data = f.read()
for off in range(0, len(data), 16):
    func_id, calls, cycles = struct.unpack_from("<IIQ", data, off)
    name = names[func_id] if func_id < len(names) else "<bad-id-%d>" % func_id
    if calls or cycles:
        rows.append((cycles, calls, func_id, name))

rows.sort(reverse=True)
total = sum(cycles for cycles, _, _, _ in rows)
print("")
print("Takibi STM32 function profile: inclusive cycles (%s)" % profile_title)
print("entries: %d, active: %d, total cycles: %d" % (len(names), len(rows), total))
print("")
print("%12s %10s %7s  %s" % ("cycles", "calls", "pct", "function"))
for cycles, calls, _func_id, name in rows[:30]:
    pct = (100.0 * cycles / total) if total else 0.0
    print("%12d %10d %6.2f%%  %s" % (cycles, calls, pct, name))

path_rows = []
with open(path_dump, "rb") as f:
    pdata = f.read()
ENTRY_SIZE = 84
MAX_DEPTH = 16
for off in range(0, len(pdata), ENTRY_SIZE):
    chunk = pdata[off:off + ENTRY_SIZE]
    if len(chunk) < ENTRY_SIZE:
        break
    h, depth, calls, cycles = struct.unpack_from("<IIIQ", chunk, 0)
    if h == 0 or depth == 0 or cycles == 0:
        continue
    frames = struct.unpack_from("<" + "I" * MAX_DEPTH, chunk, 20)
    stack = []
    for fid in frames[:min(depth, MAX_DEPTH)]:
        stack.append(names[fid] if fid < len(names) else "<bad-id-%d>" % fid)
    path_rows.append((cycles, calls, stack))

path_rows.sort(reverse=True, key=lambda r: r[0])
with open(folded_out, "w") as f:
    for cycles, _calls, stack in path_rows:
        if stack:
            f.write("%s %d\n" % (";".join(stack), cycles))

print("")
print("Folded stack output: %s" % folded_out)
print("")
print("Hottest call paths")
print("------------------")
for cycles, calls, stack in path_rows[:15]:
    pct = (100.0 * cycles / total) if total else 0.0
    print("%12d %10d %6.2f%%  %s" % (cycles, calls, pct, ";".join(stack)))
PY
