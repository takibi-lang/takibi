#!/usr/bin/env bash
# STM32 hardware integration test runner -- RAM-execution variant, called
# from repo root via: make hwcheck-stm32
#
# Supersedes the original run_hwtest.sh (deleted -- git history has it),
# which flashed every example over st-flash. This script never calls
# st-flash and never writes anything to the chip's Flash. Every STM32
# example binary is well under Flash
# Sector0's 32KB, so every one of these ~41 tests used to erase/write that
# exact same physical sector on every single `make hwcheck-stm32` run -- against
# a guaranteed minimum endurance of roughly 10,000 erase cycles per the
# datasheet, that is only ~200 hwcheck-stm32 runs before Sector0's guaranteed
# lifetime is exhausted, a real concern once hwcheck-stm32 starts running
# frequently in CI. Instead, each test here is linked against
# examples/common_stm32/link_ram.ld + startup_ram.S (AXI SRAM1 at
# 0x20010000, 240K on the F746NG) and loaded directly into RAM over the
# debug port every run -- see startup_ram.S's header comment for exactly
# how the normal hardware boot-vector fetch (which always reads from
# Flash-aliased address 0x0 and cannot itself be redirected) is bypassed:
# OpenOCD halts the core at reset, writes the linked ELF into AXI SRAM1,
# and pokes the debug SP/PC registers by hand from that image's own vector
# table before resuming -- doing manually, once, from the debugger,
# exactly what silicon would have done automatically from Flash.
#
# AXI SRAM1 is deliberately used instead of DTCM (which every other STM32
# example's ordinary Flash build still targets): DTCM sits outside the
# Cortex-M7 cache hierarchy entirely, so it would not exercise the actual
# cacheable-memory code paths this project cares about, and the Ethernet
# DMA master cannot reach DTCM at all regardless. No explicit MPU region
# is configured for it either -- see startup_ram.S for why the ARMv7-M
# architectural default memory map already gives AXI SRAM1 exactly the
# Normal/WBWA-cacheable/executable attributes this path wants.
#
# Scope: every example currently covered by the original run_hwtest.sh
# (none of them touch Ethernet DMA -- the 5 real-Ethernet examples are
# exercised separately, over real wiring, by hwcheck-stm32-net/
# run_hwtest_net_ram.sh, which also moved to RAM execution -- including a
# genuinely cacheable DMA buffer region -- in a later follow-up; see
# CLAUDE.md/HISTORY.md's RAM-execution section for both).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${STM32_SERIAL_DEV:?STM32_SERIAL_DEV is required; run 'make hwcheck-stm32' or set it explicitly}"
SERIAL_DEV="$STM32_SERIAL_DEV"
BAUD=115200
OPENOCD_BOARD_CFG="board/stm32f746g-disco.cfg"
HWTEST_ARTIFACT_ROOT="${STM32_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/hwtest-stm32}"

# shellcheck source=scripts/test_artifacts.sh
source "$(dirname "$0")/test_artifacts.sh"
ACTIVE_READER_PID=""

cleanup_reader() {
    if [ -n "$ACTIVE_READER_PID" ]; then
        kill "$ACTIVE_READER_PID" 2>/dev/null || true
        wait "$ACTIVE_READER_PID" 2>/dev/null || true
        ACTIVE_READER_PID=""
    fi
}
trap cleanup_reader EXIT
trap 'cleanup_reader; exit 130' INT TERM HUP

# Same idle-detection polling constants and reasoning as run_hwtest.sh (see
# that file's header comment) -- reused verbatim rather than re-derived,
# since the serial-side timing behavior these tune for (how long a real
# STM32 UART capture takes to go quiet) has nothing to do with how the
# firmware got onto the chip.
POLL_INTERVAL=0.05
DRAIN_MAX_SECS=1.0
DRAIN_STABLE_POLLS=6
CAPTURE_MAX_SECS=2
CAPTURE_STABLE_POLLS=4

PASS=0
FAIL=0
FAILED_TESTS=()

if [ -t 1 ]; then
    GRN='\033[32m' RED='\033[31m' RST='\033[0m'
else
    GRN='' RED='' RST=''
fi

if [ ! -e "$SERIAL_DEV" ]; then
    echo "error: $SERIAL_DEV not found -- is the STM32F746G-DISCOVERY board connected?" >&2
    exit 1
fi

# shellcheck source=scripts/stm32_hw_claim.sh
source "$(dirname "$0")/stm32_hw_claim.sh"
claim_stm32_hardware "$SERIAL_DEV"

if ! st-info --probe > /dev/null 2>&1; then
    echo "error: st-info --probe failed -- is the ST-LINK debug interface accessible?" >&2
    exit 1
fi

# read_until_quiet: identical to run_hwtest.sh's helper of the same name
# (see that file for the full comment) -- copied rather than shared via a
# second sourced file, matching this test suite's existing convention of
# each runner being a single self-contained script.
read_until_quiet() {
    local outfile="$1" max_secs="$2" stable_polls_needed="$3" wait_for_data="$4" post_start_cmd="${5:-}"
    : > "$outfile"
    cat "$SERIAL_DEV" > "$outfile" 2>/dev/null 9>&- &
    local catpid=$!
    ACTIVE_READER_PID=$catpid
    if [ -n "$post_start_cmd" ]; then
        sleep 0.1
        eval "$post_start_cmd"
    fi
    local max_polls
    max_polls=$(awk -v m="$max_secs" -v i="$POLL_INTERVAL" 'BEGIN{printf "%d", m/i}')
    local last_size=-1 stable=0 poll=0 size seen_any=0
    while [ "$poll" -lt "$max_polls" ]; do
        sleep "$POLL_INTERVAL"
        size=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
        [ "$size" -gt 0 ] && seen_any=1
        if { [ "$wait_for_data" -eq 0 ] || [ "$seen_any" -eq 1 ]; } && [ "$size" = "$last_size" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge "$stable_polls_needed" ] && break
        else
            stable=0
        fi
        last_size="$size"
        poll=$((poll + 1))
    done
    kill "$catpid" 2>/dev/null || true
    wait "$catpid" 2>/dev/null || true
    ACTIVE_READER_PID=""
}

# capture_matches: identical to run_hwtest.sh's helper (see that file for
# the ST-LINK/V2-1 0xff-prefix-artifact reasoning, which is a VCP-level
# quirk unrelated to how the target was loaded and applies here too).
capture_matches() {
    local expected="$1" actual="$2" expected_size actual_size prefix_size
    cmp -s "$expected" "$actual" && return 0
    expected_size=$(stat -c%s "$expected")
    actual_size=$(stat -c%s "$actual")
    [ "$actual_size" -gt "$expected_size" ] || return 1
    tail -c "$expected_size" "$actual" | cmp -s "$expected" - || return 1
    prefix_size=$((actual_size - expected_size))
    head -c "$prefix_size" "$actual" | od -An -v -tu1 |
        awk '{ for (i = 1; i <= NF; i++) if ($i == 255) found = 1 }
             END { exit(found ? 0 : 1) }'
}

# ram_load_and_run ELF
#
# Does, from the debug port, exactly what silicon does automatically when
# booting from Flash -- halt at reset, read the initial SP/PC out of word
# 0/word 1 of the image's own vector table, and start executing there --
# except the image lives in AXI SRAM1 rather than Flash, so the CPU's own
# hardware boot-vector fetch (hardwired to always read from Flash-aliased
# address 0x0) cannot be used to reach it. `reset halt` (never `reset
# init`) is deliberate: stm32f746g-disco.cfg's reset-init handler
# reprograms the clock tree to 192MHz for QSPI access, which every
# example's uart_init() is not expecting (see CLAUDE.md: BRR is computed
# for the default 16MHz HSI) -- `reset halt` performs a plain hardware
# reset with none of that vendor init, leaving the chip at the same clock
# configuration a real Flash boot would.
#
# Sets the caller-visible globals RAM_LOAD_OK and RAM_LOAD_LOG instead of
# returning a status directly, so it can be used as read_until_quiet's
# post_start_cmd (a plain string handed to `eval`, whose own exit status
# read_until_quiet does not propagate).
RAM_LOAD_OK=1
RAM_LOAD_LOG=""
ram_load_and_run() {
    local elf="$1"
    RAM_LOAD_LOG=$(mktemp)
    if openocd -f "$OPENOCD_BOARD_CFG" \
        -c "init" \
        -c "reset halt" \
        -c "load_image $elf 0 elf" \
        -c "set vec0 [mrw 0x20010000]" \
        -c "set vec1 [mrw 0x20010004]" \
        -c "set pcval [expr {\$vec1 & ~1}]" \
        -c "reg sp \$vec0" \
        -c "reg pc \$pcval" \
        -c "resume" \
        -c "shutdown" > "$RAM_LOAD_LOG" 2>&1
    then
        RAM_LOAD_OK=1
    else
        RAM_LOAD_OK=0
    fi
}

# ram_load_and_run_seeded ELF SEED_IMG
#
# examples/fatfs-only variant of ram_load_and_run: STM32 has no ARM
# semihosting host-file I/O, so fatfs.tkb's load_seed_from_host() is a
# stub on this target (examples/common_stm32/semihosting_stub.S) -- the
# seed FAT image instead gets written directly into the `disk` array's
# live RAM here, over the debug port, timed by a hardware breakpoint at
# app_main() so it lands after Reset_Handler's BSS-clear (which would
# otherwise zero out an earlier injection) but before fatfs.tkb's own
# Phase 1 (fat_mount()+fat_open(FA_READ, "SEED    TXT", ...)) reads it.
# `disk`/`app_main`'s addresses come from the linked ELF itself via
# llvm-nm-19, not hardcoded -- confirmed unmangled in both the QEMU and
# STM32 builds (takibi's _TK_... mangling only applies to actually
# -overloaded names, and neither is).
ram_load_and_run_seeded() {
    local elf="$1" seed_img="$2"
    local disk_addr app_main_addr
    disk_addr="0x$(llvm-nm-19 "$elf" | awk '$3=="disk"{print $1}')"
    app_main_addr="0x$(llvm-nm-19 "$elf" | awk '$3=="app_main"{print $1}')"
    RAM_LOAD_LOG=$(mktemp)
    if openocd -f "$OPENOCD_BOARD_CFG" \
        -c "init" \
        -c "reset halt" \
        -c "load_image $elf 0 elf" \
        -c "set vec0 [mrw 0x20010000]" \
        -c "set vec1 [mrw 0x20010004]" \
        -c "set pcval [expr {\$vec1 & ~1}]" \
        -c "reg sp \$vec0" \
        -c "reg pc \$pcval" \
        -c "bp $app_main_addr 2 hw" \
        -c "resume" \
        -c "wait_halt 5000" \
        -c "load_image $seed_img $disk_addr" \
        -c "rbp $app_main_addr" \
        -c "resume" \
        -c "shutdown" > "$RAM_LOAD_LOG" 2>&1
    then
        RAM_LOAD_OK=1
    else
        RAM_LOAD_OK=0
    fi
}

# dump_disk_image ELF OUT_IMG
#
# Companion to ram_load_and_run_seeded: after the target has run to
# completion (detected the same way run_hw_test_ram_fatfs detects it --
# UART output going quiet) and is idling, halts it (NOT reset -- must not
# lose the FAT12 state just written) and pulls the `disk` array's live RAM
# straight to a host file for scripts/fatfs_mtools_test.py, mirroring what
# examples/fatfs/fatfs.tkb's dump_disk_to_host() does via semihosting on
# QEMU (also not available on this target -- see semihosting_stub.S).
# 65536 = SECTOR_SIZE * TOTAL_SECTORS, the same fixed placeholder
# constants fatfs.tkb itself uses.
dump_disk_image() {
    local elf="$1" out_img="$2"
    local disk_addr dump_log
    disk_addr="0x$(llvm-nm-19 "$elf" | awk '$3=="disk"{print $1}')"
    dump_log=$(mktemp)
    local ok=1
    openocd -f "$OPENOCD_BOARD_CFG" \
        -c "init" \
        -c "halt" \
        -c "dump_image $out_img $disk_addr 65536" \
        -c "shutdown" > "$dump_log" 2>&1 || ok=0
    if [ "$ok" -ne 1 ]; then
        cat "$dump_log" >&2
    fi
    rm -f "$dump_log"
    return $((1 - ok))
}

# run_hw_test_ram_fatfs NAME ELF EXPECTED MTOOLS_SCRIPT
#
# Combines run_hw_test_ram's capture/diff with the QEMU run_fatfs_test's
# mtools cross-check: builds the same mformat/mcopy seed image
# scripts/run_qemutest.sh's run_fatfs_test uses (verbatim, not re-derived),
# runs the target via ram_load_and_run_seeded, diffs UART output against
# EXPECTED, then (once quiescent) dumps `disk`'s RAM out and hands it to
# MTOOLS_SCRIPT the same way the QEMU test does.
run_hw_test_ram_fatfs() {
    local name="$1" elf="$2" expected="$3" mtools_script="$4"
    local tmp_out tmp_dir seed_img dump_img
    tmp_out=$(mktemp)
    tmp_dir=$(mktemp -d)
    seed_img="$tmp_dir/fatfs_seed.img"
    dump_img="$tmp_dir/fatfs_disk.img"

    printf 'hello from mtools seed!\r\n' > "$tmp_dir/seedfile.txt"
    mformat -C -i "$seed_img" -t 2 -h 2 -n 32 -c 1 -r 1 -L 1 :: > /dev/null
    mcopy -i "$seed_img" "$tmp_dir/seedfile.txt" ::SEED.TXT

    stty -F "$SERIAL_DEV" "$BAUD" raw -echo
    local tmp_drain
    tmp_drain=$(mktemp)
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    rm -f "$tmp_drain"

    read_until_quiet "$tmp_out" "$CAPTURE_MAX_SECS" "$CAPTURE_STABLE_POLLS" 1 \
        "ram_load_and_run_seeded '$elf' '$seed_img'"

    if [ "$RAM_LOAD_OK" != "1" ]; then
        printf "${RED}FAIL${RST}  %s  (openocd RAM load failed)\n" "$name"
        sed 's/^/       /' "$RAM_LOAD_LOG"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        rm -f "$tmp_out" "$RAM_LOAD_LOG"
        rm -rf "$tmp_dir"
        return
    fi
    rm -f "$RAM_LOAD_LOG"

    local ok=1
    if ! capture_matches "$expected" "$tmp_out"; then
        printf "${RED}FAIL${RST}  %s (output mismatch)\n" "$name"
        printf "       expected bytes: %s\n" "$(od -An -c "$expected" | tr -s ' \n' ' ')"
        printf "       got bytes:      %s\n" "$(od -An -c "$tmp_out"  | tr -s ' \n' ' ')"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        if ! dump_disk_image "$elf" "$dump_img"; then
            printf "${RED}FAIL${RST}  %s (openocd dump_image failed)\n" "$name"
            ok=0
        elif ! python3 "$(dirname "$0")/$mtools_script" "$dump_img"; then
            printf "${RED}FAIL${RST}  %s (mtools verification failed)\n" "$name"
            ok=0
        fi
    fi

    if [ "$ok" -eq 1 ]; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$tmp_out"
    rm -rf "$tmp_dir"
}

# run_hw_test_ram NAME ELF EXPECTED [MAX_SECS] [STABLE_POLLS]
#
# RAM-execution counterpart of run_hwtest.sh's run_hw_test. Unlike that
# function, there is no separate "write" phase distinct from "run": the
# whole reset/load/poke/resume sequence happens inside ram_load_and_run,
# invoked as read_until_quiet's post_start_cmd only once a reader is
# already attached, so (unlike st-flash's own write-triggers-an-immediate-
# run quirk) there is no window in which output could be emitted before
# anything is listening.
run_hw_test_ram() {
    local name="$1" elf="$2" expected="$3" max_secs="${4:-$CAPTURE_MAX_SECS}" \
          stable_polls="${5:-$CAPTURE_STABLE_POLLS}"
    local tmp_out tmp_drain
    tmp_out=$(mktemp)
    tmp_drain=$(mktemp)

    stty -F "$SERIAL_DEV" "$BAUD" raw -echo
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    rm -f "$tmp_drain"

    read_until_quiet "$tmp_out" "$max_secs" "$stable_polls" 1 "ram_load_and_run '$elf'"

    if [ "$RAM_LOAD_OK" != "1" ]; then
        printf "${RED}FAIL${RST}  %s  (openocd RAM load failed)\n" "$name"
        sed 's/^/       /' "$RAM_LOAD_LOG"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_out" "$RAM_LOAD_LOG"
        return
    fi
    rm -f "$RAM_LOAD_LOG"

    if capture_matches "$expected" "$tmp_out"; then
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       expected bytes: %s\n" "$(od -An -c "$expected" | tr -s ' \n' ' ')"
        printf "       got bytes:      %s\n" "$(od -An -c "$tmp_out"  | tr -s ' \n' ' ')"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$tmp_out"
}

# run_hw_test_ram_suite SUITE_NAME ELF MANIFEST
#
# Load once, then retain one PASS/FAIL result per original example by
# splitting the marked UART stream with the shared suite-output checker.
run_hw_test_ram_suite() {
    local suite_name="$1" elf="$2" manifest="$3"
    local tmp_out tmp_drain report status name expected actual
    tmp_out=$(mktemp)
    tmp_drain=$(mktemp)
    report=$(mktemp)

    stty -F "$SERIAL_DEV" "$BAUD" raw -echo
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    rm -f "$tmp_drain"
    read_until_quiet "$tmp_out" "$CAPTURE_MAX_SECS" "$CAPTURE_STABLE_POLLS" 1 \
        "ram_load_and_run '$elf'"

    if [ "$RAM_LOAD_OK" != "1" ]; then
        printf "${RED}FAIL${RST}  %s (stm32/ram)  (openocd RAM load failed)\n" "$suite_name"
        sed 's/^/       /' "$RAM_LOAD_LOG"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$suite_name (stm32/ram)")
        rm -f "$tmp_out" "$report" "$RAM_LOAD_LOG"
        return
    fi
    rm -f "$RAM_LOAD_LOG"

    python3 "$(dirname "$0")/check_suite_output.py" "$tmp_out" \
        "$manifest" > "$report" || true
    [ -s "$report" ] || printf 'ERROR\tsuite checker produced no result\n' > "$report"

    while IFS=$'\t' read -r status name expected actual; do
        case "$status" in
            PASS)
                save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name (stm32/ram)" "$tmp_out" uart.log
                printf "${GRN}PASS${RST}  %s (stm32/ram)\n" "$name"
                PASS=$((PASS + 1))
                ;;
            FAIL)
                save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name (stm32/ram)" "$tmp_out" uart.log
                printf "${RED}FAIL${RST}  %s (stm32/ram)\n" "$name"
                printf "       expected bytes: %s\n" "$expected"
                printf "       got bytes:      %s\n" "$actual"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$name (stm32/ram)")
                ;;
            ERROR)
                save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$suite_name (stm32/ram)" "$tmp_out" uart.log
                printf "${RED}FAIL${RST}  %s (stm32/ram)  (%s)\n" "$suite_name" "$name"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$suite_name (stm32/ram)")
                ;;
        esac
    done < "$report"
    rm -f "$tmp_out" "$report"
}

# run_hw_test_ram_stdin NAME ELF EXPECTED STDIN_FILE
#
# RAM-execution counterpart of run_hwtest.sh's run_hw_test_stdin (echo,
# irq): waits for the first output byte before writing STDIN_FILE to the
# port, same reasoning as the original (USART's RDR is only 1 byte deep).
run_hw_test_ram_stdin() {
    local name="$1" elf="$2" expected="$3" stdin_file="$4"
    local tmp_out tmp_drain
    tmp_out=$(mktemp)
    tmp_drain=$(mktemp)

    stty -F "$SERIAL_DEV" "$BAUD" raw -echo
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    rm -f "$tmp_drain"

    : > "$tmp_out"
    cat "$SERIAL_DEV" > "$tmp_out" 2>/dev/null 9>&- &
    local catpid=$!
    ACTIVE_READER_PID=$catpid
    sleep 0.1
    ram_load_and_run "$elf"

    if [ "$RAM_LOAD_OK" != "1" ]; then
        kill "$catpid" 2>/dev/null || true
        wait "$catpid" 2>/dev/null || true
        ACTIVE_READER_PID=""
        printf "${RED}FAIL${RST}  %s  (openocd RAM load failed)\n" "$name"
        sed 's/^/       /' "$RAM_LOAD_LOG"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_out" "$RAM_LOAD_LOG"
        return
    fi
    rm -f "$RAM_LOAD_LOG"

    local max_wait_polls waited=0 size
    max_wait_polls=$(awk -v m="$CAPTURE_MAX_SECS" -v i="$POLL_INTERVAL" 'BEGIN{printf "%d", m/i}')
    while [ "$waited" -lt "$max_wait_polls" ]; do
        sleep "$POLL_INTERVAL"
        size=$(stat -c%s "$tmp_out" 2>/dev/null || echo 0)
        [ "$size" -gt 0 ] && break
        waited=$((waited + 1))
    done

    cat "$stdin_file" > "$SERIAL_DEV"

    local max_polls last_size=-1 stable=0 poll=0
    max_polls=$(awk -v m="$CAPTURE_MAX_SECS" -v i="$POLL_INTERVAL" 'BEGIN{printf "%d", m/i}')
    while [ "$poll" -lt "$max_polls" ]; do
        sleep "$POLL_INTERVAL"
        size=$(stat -c%s "$tmp_out" 2>/dev/null || echo 0)
        if [ "$size" = "$last_size" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge "$CAPTURE_STABLE_POLLS" ] && break
        else
            stable=0
        fi
        last_size="$size"
        poll=$((poll + 1))
    done
    kill "$catpid" 2>/dev/null || true
    wait "$catpid" 2>/dev/null || true
    ACTIVE_READER_PID=""

    if capture_matches "$expected" "$tmp_out"; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       expected bytes: %s\n" "$(od -An -c "$expected" | tr -s ' \n' ' ')"
        printf "       got bytes:      %s\n" "$(od -An -c "$tmp_out"  | tr -s ' \n' ' ')"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$tmp_out"
}

# run_hw_test_ram_sdcard NAME ELF SCRIPT
#
# GitHub issue #62's real SDMMC1 microSD driver (examples/sdcard) -- no
# filesystem exists at this layer, so there's nothing for `mtools` to parse
# the way examples/fatfs's own hardware test uses it. sdcard.tkb writes a
# fixed, deterministic byte pattern into a few sectors, reads them back,
# and prints both a PASS/FAIL summary and a hex dump of what it read over
# UART; SCRIPT (scripts/sdcard_test.py) independently recomputes the same
# pattern and checks the dumped bytes against it -- same "byte round trip
# through the real hardware, checked independently" principle as the
# fatfs/mtools check, just without a filesystem in the way. Destroys
# whatever was previously on the card every run (confirmed acceptable).
run_hw_test_ram_sdcard() {
    local name="$1" elf="$2" script="$3"
    local tmp_out
    tmp_out=$(mktemp)

    stty -F "$SERIAL_DEV" "$BAUD" raw -echo
    local tmp_drain
    tmp_drain=$(mktemp)
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    rm -f "$tmp_drain"

    read_until_quiet "$tmp_out" 15 8 1 "ram_load_and_run '$elf'"

    if [ "$RAM_LOAD_OK" != "1" ]; then
        printf "${RED}FAIL${RST}  %s  (openocd RAM load failed)\n" "$name"
        sed 's/^/       /' "$RAM_LOAD_LOG"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        rm -f "$tmp_out" "$RAM_LOAD_LOG"
        return
    fi
    rm -f "$RAM_LOAD_LOG"

    if python3 "$(dirname "$0")/$script" "$tmp_out"; then
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        printf "${RED}FAIL${RST}  %s\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$tmp_out"
}

echo "Running STM32 hardware integration tests (RAM execution) against $SERIAL_DEV..."
echo ""

# Every example in run_hwtest.sh's original list, unchanged expected-output
# files (RAM execution changes nothing about what bytes the firmware
# writes to UART).
run_hw_test_ram "start (stm32/ram)"         examples/start/kernel_stm32_ram.elf         examples/start/start.expected
run_hw_test_ram_suite basic_suite examples/basic_suite/kernel_stm32_ram.elf examples/basic_suite/cases.txt
run_hw_test_ram_suite type_system_suite examples/type_system_suite/kernel_stm32_ram.elf examples/type_system_suite/cases.txt
run_hw_test_ram_suite algorithm_suite examples/algorithm_suite/kernel_stm32_ram.elf examples/algorithm_suite/cases.txt
run_hw_test_ram "bump (stm32/ram)"          examples/bump/kernel_stm32_ram.elf          examples/bump/bump.expected
run_hw_test_ram "scheduler (stm32/ram)"     examples/scheduler/kernel_stm32_ram.elf     examples/scheduler/scheduler.expected

# rtc/timer: same LSI-tick-pause reasoning as run_hwtest.sh -- needs a much
# longer idle-quiet threshold than the ~200ms default.
run_hw_test_ram "rtc (stm32/ram)" examples/rtc/kernel_stm32_ram.elf examples/rtc/rtc.expected 5 40
run_hw_test_ram "timer (stm32/ram)" examples/timer/kernel_stm32_ram.elf examples/timer/timer.expected 5 40

# echo/irq: bidirectional.
run_hw_test_ram_stdin "echo (stm32/ram)" examples/echo/kernel_stm32_ram.elf examples/echo/echo.expected \
    examples/echo/echo.stdin
run_hw_test_ram_stdin "irq (stm32/ram)" examples/irq/kernel_stm32_ram.elf examples/irq/irq.expected \
    examples/irq/irq.stdin

# preempt/semaphore/condvar/msgqueue/watchdog/rtos_demo: SysTick+PendSV
# scheduler core -- exercises the VTOR relocation this whole path depends
# on for correct interrupt dispatch (startup_ram.S points VTOR at the RAM
# vector table before enabling anything that could interrupt).
run_hw_test_ram "preempt (stm32/ram)" examples/preempt/kernel_stm32_ram.elf examples/preempt/preempt.expected
run_hw_test_ram "semaphore (stm32/ram)" examples/semaphore/kernel_stm32_ram.elf examples/semaphore/semaphore.expected
run_hw_test_ram "condvar (stm32/ram)"   examples/condvar/kernel_stm32_ram.elf   examples/condvar/condvar.expected
run_hw_test_ram "msgqueue (stm32/ram)"  examples/msgqueue/kernel_stm32_ram.elf  examples/msgqueue/msgqueue.expected
run_hw_test_ram "watchdog (stm32/ram)"  examples/watchdog/kernel_stm32_ram.elf  examples/watchdog/watchdog.expected
run_hw_test_ram "rtos_demo (stm32/ram)" examples/rtos_demo/kernel_stm32_ram.elf examples/rtos_demo/rtos_demo.expected

# sdcard: real SDMMC1 microSD driver (GitHub issue #62) -- see
# run_hw_test_ram_sdcard's own comment above.
run_hw_test_ram_sdcard "sdcard (stm32/ram)" examples/sdcard/kernel_stm32_ram.elf sdcard_test.py

# fatfs: seeded RAM load (breakpoint-timed OpenOCD load_image of a real
# mformat/mcopy image into `disk`) + post-run dump_image/mtools check --
# see run_hw_test_ram_fatfs's own comment above.
run_hw_test_ram_fatfs "fatfs (stm32/ram)" examples/fatfs/kernel_stm32_ram.elf \
    examples/fatfs/fatfs_stm32.expected fatfs_mtools_test.py

# fatfs_sdcard: GitHub issue #98 -- fat12.tkb's FAT12 logic wired onto the
# real SD card via sdmmc.tkb (issue #62). Fully deterministic output (no
# timestamps, no varying data), so a plain expected-output diff suffices --
# no bespoke Python checker needed like sdcard's own hex-dump-based test.
# fat_format() alone issues ~128 real disk_write calls (each with its own
# CMD13 busy-wait poll), taking noticeably longer than the default 2s/4-poll
# capture window -- same reasoning as rtc/timer's own longer override below.
run_hw_test_ram "fatfs_sdcard (stm32/ram)" examples/fatfs_sdcard/kernel_stm32_ram.elf \
    examples/fatfs_sdcard/fatfs_sdcard.expected 15 40

# rtos_fatfs_sdcard: same real SD/FAT path as fatfs_sdcard, but the work
# runs inside an RTOS task and app_main receives completion over a Chan.
run_hw_test_ram "rtos_fatfs_sdcard (stm32/ram)" examples/rtos_fatfs_sdcard/kernel_stm32_ram.elf \
    examples/rtos_fatfs_sdcard/rtos_fatfs_sdcard.expected 15 40

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf "${GRN}All $PASS hardware test(s) passed.${RST}\n"
else
    printf "${RED}$FAIL hardware test(s) failed${RST} ($PASS passed).\n"
    printf "${RED}Failed:${RST}"
    for t in "${FAILED_TESTS[@]}"; do
        printf "  %s" "$t"
    done
    printf "\n"
fi

[ "$FAIL" -eq 0 ]
