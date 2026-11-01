#!/usr/bin/env python3
"""Every race-window kernel a lane boots is one kernelbuild-check builds (#839).

scripts/build_qemu_race_window.py names the windows. The Makefile builds an
armed and a reverted kernel for each name in KERNEL_QEMU_RACE_WINDOWS, and a
reverted kernel only for each name in KERNEL_QEMU_RACE_CONTROLS. A lane names
its window with KERNEL_QEMU_RACE_WINDOW=<name> (and skips the armed boot with
KERNEL_QEMU_RACE_WINDOW_ARMED=skip), and a script can name a kernel file
directly (kernel-race-<name>-<variant>.elf). A name missing from those lists
used to surface only when its lane ran, as a missing ELF (#830's first
negative-control run). This refuses it before any kernel is compiled.
"""

from pathlib import Path
import re
import sys

from build_qemu_race_window import WINDOWS
from pass_line import report_pass


CONTROLS_LINE = re.compile(r"^KERNEL_QEMU_RACE_CONTROLS\s*:=.*$", re.MULTILINE)


def make_list(makefile, variable):
    match = re.search(rf"^{variable}\s*:=\s*(.*)$", makefile, re.MULTILINE)
    return match.group(1).split() if match else None


def uses(texts):
    """(source, window, variant) for every kernel a lane or script boots."""
    found = []
    for source, text in texts.items():
        for line in text.splitlines():
            for name in re.findall(r"KERNEL_QEMU_RACE_WINDOW=([A-Za-z0-9-]+)", line):
                found.append((source, name, "reverted"))
                if "KERNEL_QEMU_RACE_WINDOW_ARMED=skip" not in line:
                    found.append((source, name, "armed"))
            for name, variant in re.findall(
                    r"kernel-race-([A-Za-z0-9]+(?:-[a-z0-9]+)*?)-(armed|reverted)\.elf", line):
                found.append((source, name, variant))
    return found


def validate(makefile, scripts, windows):
    errors = []
    armed_built = make_list(makefile, "KERNEL_QEMU_RACE_WINDOWS")
    controls = make_list(makefile, "KERNEL_QEMU_RACE_CONTROLS")
    if armed_built is None or controls is None:
        return ["Makefile: KERNEL_QEMU_RACE_WINDOWS or KERNEL_QEMU_RACE_CONTROLS is gone"], 0
    built = {"armed": set(armed_built), "reverted": set(armed_built) | set(controls)}
    for name in armed_built + controls:
        if name not in windows:
            errors.append(f"Makefile builds window {name}, which "
                          "scripts/build_qemu_race_window.py does not define")
    texts = {"Makefile": makefile, **scripts}
    used = uses(texts)
    for source, name, variant in used:
        if name not in windows:
            errors.append(f"{source}: boots window {name}, which "
                          "scripts/build_qemu_race_window.py does not define")
        elif name not in built[variant]:
            where = ("KERNEL_QEMU_RACE_WINDOWS" if variant == "armed"
                     else "KERNEL_QEMU_RACE_CONTROLS (or KERNEL_QEMU_RACE_WINDOWS)")
            errors.append(f"{source}: boots kernel-race-{name}-{variant}.elf, "
                          f"which kernelbuild-check never builds; add {name} to {where}"
                          + (" or pass KERNEL_QEMU_RACE_WINDOW_ARMED=skip"
                             if variant == "armed" else ""))
    return errors, len(used)


def skipped_armed(window):
    return f"KERNEL_QEMU_RACE_WINDOW={window} KERNEL_QEMU_RACE_WINDOW_ARMED=skip"


def control_errors(makefile, scripts, windows):
    """The #830 omission and an armed boot of a reverted-only control must fail.

    The subject is any reverted-only control a lane boots with the armed boot
    skipped, wherever it sits in the list: a control appended without such a
    lane shows neither failure, and neither does one also built armed (#1344).
    """
    controls = make_list(makefile, "KERNEL_QEMU_RACE_CONTROLS")
    if not controls:
        return []
    armed_built = make_list(makefile, "KERNEL_QEMU_RACE_WINDOWS") or []
    subject = next((name for name in controls
                    if name not in armed_built and skipped_armed(name) in makefile), None)
    if subject is None:
        return ["control: no skipped-armed lane names a KERNEL_QEMU_RACE_CONTROLS "
                "entry, so nothing shows an omission or an armed boot being refused"]
    errors = []
    kept = " ".join(name for name in controls if name != subject)
    omitted = CONTROLS_LINE.sub(f"KERNEL_QEMU_RACE_CONTROLS := {kept}", makefile)
    if not validate(omitted, scripts, windows)[0]:
        errors.append(f"control: dropping {subject} from "
                      "KERNEL_QEMU_RACE_CONTROLS was accepted")
    armed = makefile.replace(skipped_armed(subject), f"KERNEL_QEMU_RACE_WINDOW={subject}")
    if not validate(armed, scripts, windows)[0]:
        errors.append(f"control: an armed boot of {subject} was accepted")
    return errors


def main():
    makefile = Path("Makefile").read_text(encoding="utf-8")
    scripts = {str(path): path.read_text(encoding="utf-8")
               for path in sorted(Path("scripts").glob("*.sh"))
               if "kernel-race-" in path.read_text(encoding="utf-8")
               or "KERNEL_QEMU_RACE_WINDOW=" in path.read_text(encoding="utf-8")}
    errors, count = validate(makefile, scripts, WINDOWS)
    # Faithful controls: the #830 omission, an armed boot of a reverted-only
    # control, and a window the overlay builder does not know must each fail.
    # Their subject must not depend on the list: a new entry leaves them
    # passing, and a list no lane boots leaves them with no subject (#1344).
    errors += control_errors(makefile, scripts, WINDOWS)
    appended = CONTROLS_LINE.sub(lambda line: line.group(0) + " 999-appended", makefile)
    for error in control_errors(appended, scripts, WINDOWS):
        errors.append(f"control: appending a control with no lane failed: {error}")
    unbooted = CONTROLS_LINE.sub("KERNEL_QEMU_RACE_CONTROLS := 999-appended", makefile)
    if not control_errors(unbooted, scripts, WINDOWS):
        errors.append("control: a list no skipped-armed lane boots was accepted")
    unknown = makefile + "\n\tenv KERNEL_QEMU_RACE_WINDOW=999-unknown KERNEL_QEMU_RACE_WINDOW_ARMED=skip true\n"
    if not validate(unknown, scripts, WINDOWS)[0]:
        errors.append("control: a window the overlay builder lacks was accepted")
    if errors:
        for error in errors:
            print(f"ERROR race-window-builds: {error}")
        print("FAIL race-window-builds: a lane boots a race-window kernel "
              "that kernelbuild-check does not build")
        return 1
    report_pass("race-window-builds",
                "every race-window kernel a lane or script boots is built by "
                "kernelbuild-check; an omitted control, an armed boot of a "
                "reverted-only control and an unknown window are refused",
                kernels=count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
