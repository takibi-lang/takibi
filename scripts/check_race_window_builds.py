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


def main():
    makefile = Path("Makefile").read_text(encoding="utf-8")
    scripts = {str(path): path.read_text(encoding="utf-8")
               for path in sorted(Path("scripts").glob("*.sh"))
               if "kernel-race-" in path.read_text(encoding="utf-8")
               or "KERNEL_QEMU_RACE_WINDOW=" in path.read_text(encoding="utf-8")}
    errors, count = validate(makefile, scripts, WINDOWS)
    # Faithful controls: the #830 omission, an armed boot of a reverted-only
    # control, and a window the overlay builder does not know must each fail.
    controls = make_list(makefile, "KERNEL_QEMU_RACE_CONTROLS") or []
    if controls:
        dropped = controls[-1]
        line = "KERNEL_QEMU_RACE_CONTROLS := " + " ".join(controls)
        if line in makefile:
            omitted = makefile.replace(line, "KERNEL_QEMU_RACE_CONTROLS := "
                                       + " ".join(controls[:-1]))
            if not validate(omitted, scripts, WINDOWS)[0]:
                errors.append(f"control: dropping {dropped} from "
                              "KERNEL_QEMU_RACE_CONTROLS was accepted")
        else:
            errors.append("control: KERNEL_QEMU_RACE_CONTROLS is not one line")
        skip = f"KERNEL_QEMU_RACE_WINDOW={dropped} KERNEL_QEMU_RACE_WINDOW_ARMED=skip"
        if skip in makefile:
            armed = makefile.replace(skip, f"KERNEL_QEMU_RACE_WINDOW={dropped}")
            if not validate(armed, scripts, WINDOWS)[0]:
                errors.append(f"control: an armed boot of {dropped} was accepted")
        else:
            errors.append(f"control: no skipped-armed lane names {dropped}")
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
