#!/usr/bin/env python3
"""Controls for retrying the RPi5 post-reset safety observation."""

import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESET = ROOT / "scripts" / "rpi5_jtag_reset.sh"
LOADER = ROOT / "scripts" / "rpi5_jtag_load.sh"


FAKE_OPENOCD = r'''#!/bin/sh
set -eu
count_file="$RPI5_FAKE_COUNT"
count=0
if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf '%s\n' "$*" > "$RPI5_FAKE_ARGS.$count"
if [ "$count" -eq 1 ]; then
    printf '%s\n' 'bcm2712.cpu0 halted in AArch64 state, current mode: EL0T'
    printf '%s\n' 'pc (/64): 0x00000000400103c0'
    printf '%s\n' 'MMU: enabled'
    exit 0
fi
if [ "$count" -eq 2 ]; then
    printf '%s\n' 'bcm2712.cpu0 halted in AArch64 state, current mode: EL1H'
    printf '%s\n' 'pc (/64): 0x0000000000201000'
    printf '%s\n' 'MMU: enabled'
    exit 0
fi
if [ "$count" -eq 3 ]; then exit 0; fi
if [ "$RPI5_FAKE_CASE" = transient_then_safe ] && [ "$count" -ge 5 ]; then
    printf '%s\n' 'bcm2712.cpu0 halted in AArch64 state, current mode: EL2H'
    printf '%s\n' 'pc (/64): 0x0000000000080000'
    printf '%s\n' 'MMU: disabled'
else
    printf '%s\n' 'bcm2712.cpu0 halted in AArch64 state, current mode: EL0T'
    printf '%s\n' 'pc (/64): 0x0000000000000200'
    printf '%s\n' 'MMU: enabled'
fi
'''


def run_case(case: str) -> tuple[subprocess.CompletedProcess[str], int, list[str]]:
    with tempfile.TemporaryDirectory() as raw:
        temp = Path(raw)
        fake = temp / "openocd"
        fake.write_text(FAKE_OPENOCD, encoding="ascii")
        fake.chmod(0o755)
        count_file = temp / "count"
        env = os.environ.copy()
        env.update({
            "PATH": f"{temp}:{env['PATH']}",
            "RPI5_FAKE_COUNT": str(count_file),
            "RPI5_FAKE_ARGS": str(temp / "args"),
            "RPI5_FAKE_CASE": case,
            "RPI5_RESET_MAX_ATTEMPTS": "3",
            "RPI5_RESET_PREFLIGHT_MAX_ATTEMPTS": "3",
            "RPI5_RESET_RETRY_SECONDS": "0",
            "RPI5_OPENOCD_TIMEOUT": "2",
        })
        result = subprocess.run(
            ["bash", str(RESET), "--resident-image-unchanged"],
            cwd=ROOT, env=env, text=True, capture_output=True, check=False)
        count = int(count_file.read_text(encoding="ascii"))
        args = [
            (temp / f"args.{index}").read_text(encoding="ascii")
            for index in range(1, count + 1)
        ]
        return result, count, args


def verify() -> None:
    result, count, args = run_case("transient_then_safe")
    if result.returncode != 0:
        raise SystemExit("transient EL1 state was not retried:\n" + result.stderr)
    if count != 5:
        raise SystemExit("safe state was not accepted on the next observation")
    if "resume" in args[0] or "bp 0x200c80 4 hw" not in args[1] or \
            "wait_halt 30000" not in args[1]:
        raise SystemExit("EL0 preflight was not caught at the next EL1 IRQ")
    if "reg cpsr 0x3c5" not in args[2]:
        raise SystemExit("EL1 preflight did not preserve its exception level")
    if "resume" not in args[3]:
        raise SystemExit("transient observation left the CPU halted")

    result, count, args = run_case("never_safe")
    if result.returncode == 0:
        raise SystemExit("unsafe state was accepted")
    if count != 6:
        raise SystemExit("unsafe state did not consume the bounded retries")
    if not all("resume" in invocation for invocation in args[3:]):
        raise SystemExit("an unsafe observation left the CPU halted")
    if "after 3 attempts" not in result.stderr:
        raise SystemExit("bounded failure omitted its attempt count")


def verify_loader_injection_context() -> None:
    source = LOADER.read_text(encoding="ascii")
    required = [
        "for core in 3 2 1; do",
        'INJECT_CORE="$core"',
        'if [ "$WARM_REPLAY" = true ]; then',
        'reg pc $warm_secondary_pc',
        'bp $secondary_boot_call_pc 4 hw',
        "-c \"targets bcm2712.cpu$INJECT_CORE\"",
        "-c \"load_image $ELF 0 elf\"",
        'cache_publish_done_pc=0x00180120',
    ]
    for fragment in required:
        position = source.find(fragment)
        if position < 0:
            raise SystemExit(f"loader omits dynamic injection step: {fragment}")
    if source.find('INJECT_CORE="$core"') > source.find('-c "load_image $ELF 0 elf"'):
        raise SystemExit("loader replaces RAM before selecting its injection core")
    if 'core_mode" = "EL0T"' in source:
        raise SystemExit("loader permits an EL0 memory-access context")
    load = source.find('-c "load_image $ELF 0 elf"')
    publish = source.find('-c "bp $cache_publish_done_pc 4 hw"')
    if not load < publish:
        raise SystemExit("loader does not publish the replaced image after loading")

    reset_source = RESET.read_text(encoding="ascii")
    required_reset = [
        "CACHE_PUBLISH_ADDR=0x00180100",
        '-c \'targets bcm2712.cpu0\'',
        '-c "mww $CACHE_PUBLISH_ADDR 0xd50b7e20"',
        '-c "mww $((CACHE_PUBLISH_ADDR + 32)) 0x14000000"',
    ]
    for fragment in required_reset:
        if fragment not in reset_source:
            raise SystemExit(f"reset omits persistent cache helper step: {fragment}")



def main() -> int:
    verify()
    verify_loader_injection_context()
    print("RPi5 JTAG reset controls passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
