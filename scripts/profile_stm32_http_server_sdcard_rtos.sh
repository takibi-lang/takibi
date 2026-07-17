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

# shellcheck source=scripts/stm32_hw_claim.sh
source "$(dirname "$0")/stm32_hw_claim.sh"
claim_stm32_hardware "$STM32_SERIAL_DEV"

tmpdir=$(mktemp -d)
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

echo "Provisioning SD card content..."
bash scripts/provision_http_server_sdcard.sh "$INSTALLER_ELF" "$CONTENT_DIR" > "$tmpdir/provision.log" 2>&1 || {
    echo "SD card provisioning failed:" >&2
    sed 's/^/       /' "$tmpdir/provision.log" >&2
    exit 1
}

echo "Loading profiled HTTP+SD+RTOS firmware..."
ram_load_and_run "$ELF"

echo "Fetching $URL ..."
curl_ok=0
for attempt in $(seq 1 "${TAKIBI_PROFILE_CURL_ATTEMPTS:-10}"); do
    if curl --fail --silent --show-error --max-time "${TAKIBI_PROFILE_CURL_TIMEOUT:-90}" \
        --output "$tmpdir/ICON.PNG" "$URL"; then
        curl_ok=1
        break
    fi
    echo "curl attempt $attempt failed; retrying..." >&2
    sleep 1
done
if [ "$curl_ok" -ne 1 ]; then
    echo "curl failed after ${TAKIBI_PROFILE_CURL_ATTEMPTS:-10} attempts" >&2
    exit 1
fi

table_addr=$(llvm-nm-19 "$ELF" | awk '$3 == "__takibi_prof_table" { print "0x" $1; exit }')
if [ -z "$table_addr" ]; then
    echo "could not find __takibi_prof_table in $ELF" >&2
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
        if name == "pendsv_dispatch" or name.endswith("Handler"):
            continue
        names.append(name)
print(len(sorted(names)))
PY
)
table_size=$((profile_count * 16))
dump="$tmpdir/takibi_prof_table.bin"

echo "Dumping $profile_count profile entries from $table_addr ..."
dump_profile_table "$table_addr" "$table_size" "$dump"

python3 - "$OBJ" "$dump" <<'PY'
import struct
import subprocess
import sys

obj, dump = sys.argv[1], sys.argv[2]
out = subprocess.check_output(["llvm-nm-19", obj], text=True)
names = []
for line in out.splitlines():
    parts = line.split()
    if len(parts) >= 3 and parts[1] == "T":
        name = parts[2]
        if name == "pendsv_dispatch" or name.endswith("Handler"):
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
PY
