#!/usr/bin/env python3
"""Build real-GEM ownership and IRQ regression source overlays."""

import argparse
import os
from pathlib import Path
import shutil


def replace_once(path, before, after):
    text = path.read_text(encoding="ascii")
    if text.count(before) != 1:
        raise ValueError(f"GEM fixture anchor must occur once in {path}: {before!r}")
    path.write_text(text.replace(before, after), encoding="ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("overlay", type=Path)
    parser.add_argument("mode", choices=("confirmed-ready", "confirmed-reply",
                                        "unconfirmed-ready", "unconfirmed-reply",
                                        "irq-primary", "irq-wrong-enable"))
    parser.add_argument("--control", choices=("device-access", "queue-bank", "raw-irq"))
    args = parser.parse_args()
    root, overlay = args.root.resolve(), args.overlay.resolve()
    if not (overlay.is_relative_to(root / ".git") or
            overlay.is_relative_to(root / "_build")):
        raise ValueError("overlay must be an isolated .git/_build directory")
    kernel = overlay / "kernel"
    if kernel.exists():
        shutil.rmtree(kernel)
    changed = {"platform/rpi5/init.tkb", "drivers/net/rp1_gem.tkb"}
    if args.control:
        changed.add("tests/rpi5/gem_tx/fixture.tkb")
    for current, directories, files in os.walk(root / "kernel"):
        directories[:] = [name for name in directories if name != "build"]
        relative = Path(current).relative_to(root / "kernel")
        target = kernel / relative
        target.mkdir(parents=True, exist_ok=True)
        for name in files:
            source = Path(current) / name
            if (relative / name).as_posix() in changed:
                shutil.copyfile(source, target / name)
            else:
                (target / name).symlink_to(source)
    # Embedded production images remain inputs, not overlay output paths.
    (kernel / "build").symlink_to(root / "kernel/build", target_is_directory=True)

    if args.mode.startswith("irq-"):
        init = kernel / "platform/rpi5/init.tkb"
        text = init.read_text(encoding="ascii")
        start = text.index("fn kernel_test_platform_network() {")
        end = text.index("\n}\n", start) + 3
        body = """fn kernel_test_platform_network() {
    match net_init() {
        NetInitResult::Failed => { kernel_boot_log("FAIL gem-probe: init\\n"); }
        NetInitResult::Ready(ready) => {
            kernel_boot_log("gem-probe: mode MODE\\n");
            gem_probe_run(ready);
        }
    }
    while (true) { workload_profile_interrupt_wait(); }
}
""".replace("MODE", args.mode)
        init.write_text('use "kernel/tests/rpi5/gem_tx/irq_fixture.tkb";\n' +
                        text[:start] + body + text[end:], encoding="ascii")
        driver = kernel / "drivers/net/rp1_gem.tkb"
        replace_once(driver, "    workload_profile_note_network_tx(safe_len as usize);",
                     "    gem_probe_note_submit();\n    workload_profile_note_network_tx(safe_len as usize);")
        replace_once(driver, "    let isr: u32 = gem.isr;",
                     "    let isr: u32 = gem.isr;\n    gem_probe_note_irq(isr);")
        wait = kernel / "drivers/net/gem_tx_wait.tkb"
        wait.unlink()
        shutil.copyfile(root / "kernel/drivers/net/gem_tx_wait.tkb", wait)
        replace_once(wait, "if (gem_tx_slot_done(slot)) { return true; }",
                     "if (gem_tx_slot_done(slot)) { gem_probe_note_done(); return true; }")
        replace_once(wait, "        workload_profile_interrupt_wait();",
                     "        workload_profile_interrupt_wait();\n        gem_probe_note_wake();")
        if args.mode == "irq-wrong-enable":
            # Keep the primary bank masked, but enable the wrong additional
            # queue as the old driver did. Primary ISR/IDR remain correct to
            # avoid a warm-reload unacknowledged level interrupt storm.
            import re
            text = driver.read_text(encoding="ascii")
            start = text.index("io struct Rp1GemRegs {")
            end = text.index("\n}", start)
            fields = re.findall(r"    (\w+): u32 at (0x[0-9A-F]+);", text[start:end])
            fields = [(name, 0x600 if name == "ier" else int(offset, 16)) for name, offset in fields]
            block = "io struct Rp1GemRegs {\n" + "\n".join(
                f"    {name}: u32 at 0x{offset:02X};" for name, offset in sorted(fields, key=lambda field: field[1]))
            driver.write_text(text[:start] + block + text[end:], encoding="ascii")
        return

    init = kernel / "platform/rpi5/init.tkb"
    text = init.read_text(encoding="ascii")
    start = text.index("fn kernel_test_platform_network() {")
    end = text.index("\n}\n", start) + 3
    unconfirmed = str(args.mode.startswith("unconfirmed")).lower()
    reply = str(args.mode.endswith("reply")).lower()
    body = """fn kernel_test_platform_network() {
    match net_init() {
        NetInitResult::Failed => {
            gem_fixture_require(false, "physical GEM initialization");
        }
        NetInitResult::Ready(ready) => {
            kernel_boot_log("gem-tx fixture: mode MODE\\n");
            gem_fixture_hide_halt = UNCONFIRMED;
            gem_fixture_reply_path = REPLY;
            gem_fixture_run(ready);
        }
    }
    while (true) { workload_profile_interrupt_wait(); }
}
""".replace("UNCONFIRMED", unconfirmed).replace("REPLY", reply).replace("MODE", args.mode)
    init.write_text('use "kernel/tests/rpi5/gem_tx/fixture.tkb";\n' +
                    text[:start] + body + text[end:], encoding="ascii")

    driver = kernel / "drivers/net/rp1_gem.tkb"
    replace_once(driver, "    workload_profile_note_network_tx(safe_len as usize);",
                 "    gem_fixture_submissions = gem_fixture_submissions + 1;\n"
                 "    workload_profile_note_network_tx(safe_len as usize);")
    # Observe the real USED bit before hiding it from the maintained wait.
    for slot, word in ((0, 1), (1, 5)):
        result = f"(gem_tx_desc[{word}] & (1 << 31)) != 0"
        before = (f"    if (slot == 0) {{ return {result}; }}" if slot == 0
                  else f"    return {result};")
        after = ("    if (slot == 0) {\n" if slot == 0 else "")
        indent = "        " if slot == 0 else "    "
        after += (indent + f"let observed: bool = {result};\n" +
                  indent + "if (observed) { gem_fixture_observed_used = true; }\n" +
                  indent + "return observed && gem_fixture_hide_completion == false;" +
                  ("\n    }" if slot == 0 else ""))
        replace_once(driver, before, after)
    replace_once(driver, "        if ((gem.tsr & (1 << 3)) == 0) {",
                 "        let observed: u32 = gem.tsr;\n"
                 "        gem_fixture_last_tsr = observed;\n"
                 "        if ((observed & (1 << 3)) == 0 &&\n"
                 "                gem_fixture_hide_halt == false) {")
    if args.control == "device-access":
        fixture = kernel / "tests/rpi5/gem_tx/fixture.tkb"
        fixture.write_text(fixture.read_text(encoding="ascii") + """
// Real generated GEM authority must reject a Device-to-CPU access bridge.
fn gem_fixture_invalid_access(device: borrow *GemTxDevice) {
    let bytes = dma_cpu_slice(device, GemTx);
    bytes[0] = 1;
}
""", encoding="ascii")
    if args.control in ("queue-bank", "raw-irq"):
        fixture = kernel / "tests/rpi5/gem_tx/fixture.tkb"
        access = "gem.queue1_isr" if args.control == "queue-bank" else "gem_read(0x400)"
        fixture.write_text(fixture.read_text(encoding="ascii") +
                           "\n// The real GEM API must exclude the additional queue bank.\n" +
                           "fn gem_fixture_invalid_irq_bank() -> u32 { return " +
                           access + "; }\n", encoding="ascii")


if __name__ == "__main__":
    main()
