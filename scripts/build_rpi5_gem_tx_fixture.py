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


# The window-closed mode's additions to the fixture. The runner, not this code,
# judges the printed values (scripts/run_kernel_gem_tx_rpi5.py).
#
# GitHub issue #1254: moving the window off the arena stops GEM at its descriptor
# read, which proves the read direction again. The write that protects kernel
# memory needs a descriptor GEM can read and a buffer outside the window, so the
# RX control leaves the window on the arena and only points the descriptor away.
# Both stages run the same code on real frames from the runner's peer; the first
# shows that this path does write when the buffer is inside the window.
WINDOW_CLOSED_FIXTURE = """
fn gem_fixture_close_window() !{unsafe} {
    gem_fixture_print_inbound_bars();
    let moved: u32 = (rp1_dma_arena_start as u32) + 0x40000;
    pcie2.ubus_bar2_remap_lo = 0;
    pcie2.rc_bar2_lo = moved | RP1_DMA_ARENA_SIZE_ENCODING;
    pcie2.ubus_bar2_remap_lo = moved | 1;
    let settled: u32 = pcie2.ubus_bar2_remap_lo;
    kernel_boot_log("gem-tx fixture: window moved to ");
    uart_put_udec(settled as usize);
    kernel_boot_log("\\n");
}

fn gem_fixture_print_bar(bar: usize, lo: u32, remap: u32) {
    kernel_boot_log("gem-tx fixture: inbound bar ");
    uart_put_udec(bar);
    kernel_boot_log(" lo=");
    uart_put_udec(lo as usize);
    kernel_boot_log(" remap=");
    uart_put_udec(remap as usize);
    kernel_boot_log("\\n");
}

// Slots 1..3 sit in the first register bank, 4..10 in the second, each slot
// one LO/HI pair. Only LO holds the size and only REMAP_LO the enable.
fn gem_fixture_print_inbound_bars() !{unsafe} {
    gem_fixture_print_bar(1, pcie2.rc_bar1_lo, pcie2.ubus_bar1_remap_lo);
    gem_fixture_print_bar(2, pcie2.rc_bar2_lo, pcie2.ubus_bar2_remap_lo);
    gem_fixture_print_bar(3, pcie2.rc_bar3_lo, pcie2.ubus_bar3_remap_lo);
    for slot: usize in 0..<7 {
        let word: usize = slot * 2;
        if (word < 14) {
            gem_fixture_print_bar(slot + 4, pcie2.rc_bar4_to_10[word], pcie2.ubus_bar4_to_10[word]);
        }
    }
}

"""

# The driver is a raw mint file, so the raw half of the control is appended there.
WINDOW_CLOSED_DRIVER = """
fn gem_fixture_store(address: usize, value: usize) !{unsafe} {
    unsafe { atomic_store_release(address, value); }
}
fn gem_fixture_load(address: usize) -> usize !{unsafe} {
    return unsafe { atomic_load_acquire(address) };
}

let mut gem_fixture_rx_outside: [u8; 2048] align(64);

// One receive with RX re-enabled by hand: the MAC is halted and this control
// is the last thing the image does, so no driver owner is live on the path.
fn gem_fixture_rx_stage(name: *u8, desc: usize, buffer: usize) !{unsafe} {
    gem.ncr = 1 << 4;
    for offset: usize in 0..<256 {
        gem_fixture_store(buffer + offset * 8, 0xA5A5A5A5A5A5A5A5);
    }
    dma_prepare_tx(unsafe { buffer as *u8 }, 2048);
    dma_finish_rx(unsafe { buffer as *align(64) u8 }, 2048);
    let bus: usize = buffer + boot_once_get(&rp1_dma_pci_offset);
    gem_fixture_store(desc, (bus & 0xFFFFFFFC) | 2);
    gem_fixture_store(desc + 8, bus >> 32);
    dma_prepare_tx(unsafe { desc as *u8 }, 16);
    let desc_bus: usize = desc + boot_once_get(&rp1_dma_pci_offset);
    gem.rbqp = desc_bus as u32;
    gem.rbqph = (desc_bus >> 32) as u32;
    gem.rsr = 0x0F;
    let cleared: u32 = gem.frames_rx;
    gem.ncr = (1 << 4) | (1 << 2);
    let start: i64 = read_cntpct();
    let deadline: i64 = read_cntfrq() / 2;
    while (read_cntpct() - start < deadline) {
    }
    gem.ncr = 1 << 4;
    let frames: u32 = gem.frames_rx;
    let rsr: u32 = gem.rsr;
    let isr: u32 = gem.isr;
    dma_finish_rx(unsafe { desc as *align(64) u8 }, 64);
    dma_finish_rx(unsafe { buffer as *align(64) u8 }, 2048);
    let own: usize = gem_fixture_load(desc) & 1;
    let mut changed: usize = 0;
    for offset: usize in 0..<256 {
        if (gem_fixture_load(buffer + offset * 8) != 0xA5A5A5A5A5A5A5A5) {
            changed = changed + 1;
        }
    }
    kernel_boot_log("gem-tx fixture: rx stage ");
    uart_puts(name);
    kernel_boot_log(" frames=");
    uart_put_udec(frames as usize);
    kernel_boot_log(" own=");
    uart_put_udec(own);
    kernel_boot_log(" rsr=");
    uart_put_udec(rsr as usize);
    kernel_boot_log(" isr=");
    uart_put_udec(isr as usize);
    kernel_boot_log(" changed=");
    uart_put_udec(changed);
    kernel_boot_log(" word1=");
    uart_put_udec(gem_fixture_load(buffer + 8));
    kernel_boot_log("\\n");
}

fn gem_fixture_rx_control() !{unsafe} {
    pcie2_dma_inbound_setup();
    let desc: usize = gem_rx_ring_cpu_address;
    dma_finish_rx(unsafe { desc as *align(64) u8 }, 64);
    let inside_bus: usize = (gem_fixture_load(desc) & 0xFFFFFFFC) |
                            (gem_fixture_load(desc + 8) << 32);
    let inside: usize = inside_bus - boot_once_get(&rp1_dma_pci_offset);
    let outside: usize = (gem_fixture_rx_outside as *u8) as usize;
    let arena: usize = rp1_dma_arena_start as usize;
    gem_fixture_require(inside >= arena && inside + 2048 <= arena + 0x40000,
                        "RX buffer inside the arena");
    gem_fixture_require(outside + 2048 <= arena || outside >= arena + 0x40000,
                        "sentinel outside the arena");
    gem_fixture_rx_stage("inside", desc, inside);
    gem_fixture_rx_stage("outside", desc, outside);
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("overlay", type=Path)
    parser.add_argument("mode", choices=("confirmed-ready", "confirmed-reply",
                                        "unconfirmed-ready", "unconfirmed-reply",
                                        "irq-primary", "irq-wrong-enable",
                                        "window-closed"))
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
    if args.control or args.mode == "window-closed":
        changed.add("tests/rpi5/gem_tx/fixture.tkb")
    if args.mode == "window-closed":
        changed.add("platform/rpi5/pcie.tkb")
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
    match network_capability_take() {
        NetworkCapabilityTakeResult::Empty => { kernel_boot_log("FAIL gem-probe: init\\n"); }
        NetworkCapabilityTakeResult::Ready(ready) => {
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
    match network_capability_take() {
        NetworkCapabilityTakeResult::Empty => {
            gem_fixture_require(false, "physical GEM initialization");
        }
        NetworkCapabilityTakeResult::Ready(ready) => {
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
    replace_once(driver, "    return gem_tx_ring_poll(slot);",
                 "    let observed: bool = gem_tx_ring_poll(slot);\n"
                 "    if (observed) { gem_fixture_observed_used = true; }\n"
                 "    return observed && gem_fixture_hide_completion == false;")
    replace_once(driver, "        if ((gem.tsr & (1 << 3)) == 0) {",
                 "        let observed: u32 = gem.tsr;\n"
                 "        gem_fixture_last_tsr = observed;\n"
                 "        if ((observed & (1 << 3)) == 0 &&\n"
                 "                gem_fixture_hide_halt == false) {")
    if args.mode == "window-closed":
        # GitHub issue #1032 (B'): after six good transfers, slide
        # the inbound window off the arena. The address stays what the driver
        # hands GEM; only the window no longer covers it, so the next TX must
        # not complete and no frame may reach the wire.
        fixture = kernel / "tests/rpi5/gem_tx/fixture.tkb"
        replace_once(fixture, "    gem_fixture_hide_completion = true;\n",
                     "    gem_fixture_close_window();\n")
        replace_once(fixture, """    gem_fixture_require(gem_fixture_observed_used,
                        "a real USED observation was hidden");
""", """    gem_fixture_require(gem_fixture_observed_used == false,
                        "TX completed through a closed window");
""")
        # RX cannot deliver through a closed window either.
        replace_once(fixture, "    ready = gem_fixture_reply(ready, true);\n", "")
        # GitHub issue #1254: the window's other half, on registers production
        # never touches. Declared here so they stay out of the kernel image.
        pcie = kernel / "platform/rpi5/pcie.tkb"
        replace_once(pcie, "    rc_bar2_hi: u32 at 0x4038;\n",
                     "    rc_bar2_hi: u32 at 0x4038;\n"
                     "    rc_bar3_lo: u32 at 0x403C;\n")
        replace_once(pcie, "    ubus_bar2_remap_hi: u32 at 0x40B8;\n",
                     "    ubus_bar2_remap_hi: u32 at 0x40B8;\n"
                     "    ubus_bar3_remap_lo: u32 at 0x40BC;\n"
                     "    rc_bar4_to_10: [u32; 14] at 0x40D4;\n"
                     "    ubus_bar4_to_10: [u32; 14] at 0x410C;\n")
        replace_once(driver, "    sa1_top: u32 at 0x8C;\n",
                     "    sa1_top: u32 at 0x8C;\n"
                     "    frames_rx: u32 at 0x158;\n")
        driver.write_text(driver.read_text(encoding="ascii") + WINDOW_CLOSED_DRIVER,
                          encoding="ascii")
        replace_once(fixture, "    net_shutdown(ready);\n",
                     "    gem_fixture_rx_control();\n    net_shutdown(ready);\n")
        fixture.write_text(fixture.read_text(encoding="ascii") + WINDOW_CLOSED_FIXTURE,
                           encoding="ascii")
    if args.control == "device-access":
        fixture = kernel / "tests/rpi5/gem_tx/fixture.tkb"
        fixture.write_text(fixture.read_text(encoding="ascii") + """
// The real GEM packet owner must reject a write while GEM reads it.
fn gem_fixture_invalid_access(posted: borrow GemPkt_TxPosted[b, o, 1, r]) {
    let bytes = GemPkt_TxPosted_bytes(posted, 0);
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
