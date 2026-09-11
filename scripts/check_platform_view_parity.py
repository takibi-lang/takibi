#!/usr/bin/env python3
"""A test that only one lane runs, and no sentence saying why.

The kernel is judged by views: a filter selects lines from one boot's UART
capture and the selection is compared to an expected file. Most live in
`kernel/tests/common/views/` and are compared on BOTH lanes. Some live under
`kernel/tests/<platform>/views/` and are compared on one.

Being platform-specific is a real thing to be -- `rp1 gem` and `virtio net`
are different devices -- but it is also what a view is by ACCIDENT, because a
view is filed where it was written. Nothing distinguishes those two, and the
difference is the whole value of the second lane:

  * `ext2_mutation` ran four mutation probes on QEMU that the board never ran.
    Measured against a real capture on 2026-09-08: zero occurrences of all
    four on RPi5. Nothing about them was platform-specific.
  * `httpd_network_retransmit` was compared only on the board, while QEMU
    emitted both of its lines on every boot and no filter matched them.
  * `linux_file` had a QEMU filter that was NARROWER than the common one, so
    the lane that runs on every push asserted one of the two lines the board
    asserted -- and QEMU emits both.
  * `distro_image` had byte-identical expected files in both platform
    directories.

All four were found by a person looking, twice by accident. That is the thing
this check replaces. It does not decide whether a view should be common --
it cannot -- it requires the answer to have been WRITTEN, once, by whoever
put the view on one lane.

WHAT IS DECLARED IS ALLOWED, AND NOTHING ELSE. A new platform-only view fails
until it is named below with its reason, and a declaration that outlives its
view fails too: an exemption list whose entries no longer name anything reads
as current and is worse than no list at all.
"""

import pathlib
import sys

from pass_line import report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
VIEW_ROOT = REPO / "kernel" / "tests"
# Lanes with their own view directory. `qemu-debug` is an expected-content
# overlay selected by KERNEL_QEMU_EXPECTED_VIEW_DIR rather than a lane with
# filters of its own, and is held to the same rule.
LANES = ("qemu", "rpi5", "qemu-debug")

# (lane, view name) -> why this view is not in common/views/.
ALLOWED = {
    ("qemu-debug", "boot"):
        "the debug image falls in a different 32 KiB allocation granule "
        "from the release QEMU image once the issue #208 block cache's "
        "slots are linked, so its usable-RAM start differs by one granule",
    ("qemu", "boot"):
        "the boot inventory is the machine's own physical facts -- DTB memory "
        "base, detected size, allocator pages, and the GIC/UART addresses "
        "QEMU's virt machine reports. The board's equivalent names a system "
        "timer instead. Nothing here can be shared and stay an assertion",
    ("rpi5", "boot"):
        "the same inventory for the board: 1019 MiB behind two reservations, "
        "and the RP1 system timer cross-checked against the architected "
        "counter, which QEMU has no equivalent of",
    ("qemu", "network"):
        "the same test as rpi5/ethernet, named for the device that runs it: "
        "virtio-net against the host peer",
    ("rpi5", "ethernet"):
        "the same test as qemu/network, on RP1's GEM",
    ("qemu", "storage"):
        "the same test as rpi5/usb_storage on a different transport: virtio "
        "blk, including its used-index wrap, which has no USB counterpart, "
        "and naming the virtio disk as the root filesystem's device",
    ("rpi5", "usb_storage"):
        "the same test as qemu/storage over USB mass storage, including the "
        "provisioning step that writes the filesystem to the stick, and "
        "naming the stick as the root filesystem's device",
}


def views_in(lane: str) -> set:
    directory = VIEW_ROOT / lane / "views"
    if not directory.exists():
        return set()
    return {path.stem for path in directory.iterdir()
            if path.suffix in (".filter", ".expected")}


def main() -> int:
    problems = []
    declared = 0
    seen = set()
    for lane in LANES:
        for name in sorted(views_in(lane)):
            seen.add((lane, name))
            if (lane, name) in ALLOWED:
                declared += 1
                continue
            problems.append(
                f"kernel/tests/{lane}/views/{name}.*: compared on the {lane} "
                f"lane only, and nothing says why. If the evidence is not "
                f"platform-specific, move it to kernel/tests/common/views/ so "
                f"both lanes compare it; if it is, declare it in "
                f"{pathlib.Path(__file__).name} with the reason")

    for lane, name in sorted(ALLOWED):
        if (lane, name) not in seen:
            problems.append(
                f"kernel/tests/{lane}/views/{name}.*: declared platform-"
                f"specific here, and no such view exists any more. Remove the "
                f"declaration -- every entry left has to be one a reviewer can "
                f"go and read")

    # A platform expected file whose content matches another platform's is
    # duplication rather than specificity, whatever the declaration says.
    for left in LANES:
        for right in LANES:
            if left >= right:
                continue
            for name in sorted(views_in(left) & views_in(right)):
                one = VIEW_ROOT / left / "views" / f"{name}.expected"
                two = VIEW_ROOT / right / "views" / f"{name}.expected"
                if one.exists() and two.exists() and \
                        one.read_bytes() == two.read_bytes():
                    problems.append(
                        f"kernel/tests/{left}/views/{name}.expected and "
                        f"kernel/tests/{right}/views/{name}.expected are "
                        f"byte-identical. That is one view in two places, not "
                        f"two platform-specific ones -- move it to "
                        f"kernel/tests/common/views/")

    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"FAIL platform-view-parity: {len(problems)} view(s) are "
              "compared on one lane without a stated reason", file=sys.stderr)
        return 1
    common = len({path.stem for path in
                  (VIEW_ROOT / "common" / "views").glob("*.filter")})
    report_pass("platform-view-parity",
                f"{common} views are compared on every lane and {declared} are "
                "declared platform-specific with the reason written beside "
                "them; no platform expected file duplicates another's",
                counts=declared)
    return 0


if __name__ == "__main__":
    sys.exit(main())
