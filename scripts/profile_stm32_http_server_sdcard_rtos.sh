#!/usr/bin/env bash
# Profiles examples/http_server_sdcard_rtos on real STM32 hardware.
#
# The firmware is built with takibi --profile-functions, loaded into AXI SRAM1,
# exercised by a single host curl for /ICON.PNG, then halted so OpenOCD can
# dump __takibi_prof_table from RAM. The table format is fixed by
# lib/llvm_gen.ml:
#   struct Entry { u32 id; u32 calls; u64 inclusive_cycles; }
set -euo pipefail

: "${STM32_SERIAL_DEV:?STM32_SERIAL_DEV is required; run through make or set it explicitly}"

OPENOCD_BOARD_CFG="board/stm32f746g-disco.cfg"
ELF="examples/http_server_sdcard_rtos/kernel_stm32_ram.prof.elf"
OBJ="examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.prof.o"
INSTALLER_ELF="examples/http_server_sdcard_install/kernel_stm32_ram.elf"
CONTENT_DIR="examples/sdcard_content"
URL="${TAKIBI_PROFILE_URL:-http://192.168.10.2/ICON.PNG}"
OUT_DIR="${TAKIBI_PROFILE_OUT_DIR:-_build/takibi_profile/http_server_sdcard_rtos}"
# Must match prof_path_max_depth/capacity in lib/llvm_gen.ml.
PATH_ENTRY_SIZE=68
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
    local table_addr="$1" count="$2" path_addr="$3" path_size="$4" overflow_addr="$5" stack_overflow_addr="$6" log
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
        -c "mww $overflow_addr 0" \
        -c "mww $stack_overflow_addr 0" \
        -c "resume" \
        -c "shutdown" > "$log" 2>&1 || {
            echo "openocd profile clear failed:" >&2
            sed 's/^/       /' "$log" >&2
            return 1
        }
}

fetch_icon() {
    local label="$1"
    local curl_ok=0
    echo "Fetching $URL ($label) ..."
    for attempt in $(seq 1 "${TAKIBI_PROFILE_CURL_ATTEMPTS:-10}"); do
        if curl --fail --silent --show-error --max-time "${TAKIBI_PROFILE_CURL_TIMEOUT:-90}" \
            --output "$tmpdir/ICON-$label.PNG" "$URL"; then
            curl_ok=1
            break
        fi
        echo "curl $label attempt $attempt failed; retrying..." >&2
        sleep 1
    done
    if [ "$curl_ok" -ne 1 ]; then
        echo "curl $label failed after ${TAKIBI_PROFILE_CURL_ATTEMPTS:-10} attempts" >&2
        exit 1
    fi
}

echo "Provisioning SD card content..."
bash scripts/provision_http_server_sdcard.sh "$INSTALLER_ELF" "$CONTENT_DIR" > "$tmpdir/provision.log" 2>&1 || {
    echo "SD card provisioning failed:" >&2
    sed 's/^/       /' "$tmpdir/provision.log" >&2
    exit 1
}

echo "Loading profiled HTTP+SD+RTOS firmware..."
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
overflow_addr=$(llvm-nm-19 "$ELF" | awk '$3 == "__takibi_prof_path_overflow" { print "0x" $1; exit }')
if [ -z "$overflow_addr" ]; then
    echo "could not find __takibi_prof_path_overflow in $ELF" >&2
    exit 1
fi
stack_overflow_addr=$(llvm-nm-19 "$ELF" | awk '$3 == "__takibi_prof_overflow" { print "0x" $1; exit }')
if [ -z "$stack_overflow_addr" ]; then
    echo "could not find __takibi_prof_overflow in $ELF" >&2
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
overflow_dump="$tmpdir/takibi_prof_path_overflow.bin"
stack_overflow_dump="$tmpdir/takibi_prof_overflow.bin"

fetch_icon "warm"

echo "Clearing profile counters after warm-up..."
clear_profile_counters_and_resume "$table_addr" "$profile_count" "$path_addr" "$path_size" "$overflow_addr" "$stack_overflow_addr"

fetch_icon "measured"

echo "Dumping $profile_count profile entries from $table_addr ..."
dump_profile_table "$table_addr" "$table_size" "$dump"
echo "Dumping $PATH_ENTRY_COUNT call-path entries from $path_addr ..."
dump_profile_table "$path_addr" "$path_size" "$path_dump"
dump_profile_table "$overflow_addr" 4 "$overflow_dump"
overflow_count=$(od -An -tu4 "$overflow_dump" | tr -d ' ')
if [ "$overflow_count" -ne 0 ]; then
    echo "call-path table overflowed $overflow_count times" >&2
    exit 1
fi
dump_profile_table "$stack_overflow_addr" 4 "$stack_overflow_dump"
stack_overflow_count=$(od -An -tu4 "$stack_overflow_dump" | tr -d ' ')
if [ "$stack_overflow_count" -ne 0 ]; then
    echo "call-stack depth overflowed $stack_overflow_count times (prof_stack_capacity in lib/llvm_gen.ml is too small for this run)" >&2
    exit 1
fi

python3 - "$OBJ" "$dump" "$path_dump" "$OUT_DIR/profile.folded" <<'PY'
import struct
import subprocess
import sys

obj, dump, path_dump, folded_out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
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
print("Takibi STM32 function profile: inclusive cycles")
print("entries: %d, active: %d, total cycles: %d" % (len(names), len(rows), total))
print("")
print("%12s %10s %7s  %s" % ("cycles", "calls", "pct", "function"))
for cycles, calls, _func_id, name in rows[:30]:
    pct = (100.0 * cycles / total) if total else 0.0
    print("%12d %10d %6.2f%%  %s" % (cycles, calls, pct, name))

path_rows = []
with open(path_dump, "rb") as f:
    pdata = f.read()
ENTRY_SIZE = 68
MAX_DEPTH = 12
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
