#!/usr/bin/env python3
"""Keep every Takibi object linked into an EL0 PIE on the shared audit recipe."""
import re
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent


def audit_recipe_problems(text):
    definitions = dict(re.findall(r"^(\w+)\s*:?=\s*(.*)$", text, re.M))
    rules = {}
    for match in re.finditer(r"^\$\((\w+)\):([^\n]*)\n((?:\t[^\n]*\n)+)", text, re.M):
        rules[match[1]] = (re.findall(r"\$\((\w+)\)", match[2]), match[3])
    objects = set()
    for prerequisites, recipe in rules.values():
        if "$(LLD)" not in recipe or "-pie" not in recipe:
            continue
        for name in prerequisites:
            source_rule = rules.get(name)
            if source_rule and source_rule[0]:
                source = definitions.get(source_rule[0][0], "")
                if source.endswith(".tkb"):
                    objects.add(name)
    problems = []
    if not objects:
        problems.append("no standalone EL0 Takibi object rules found")
    macro = re.search(r"^define KERNEL_EL0_COMPILE\n(.*?)^endef$", text, re.M | re.S)
    body = macro[1] if macro else ""
    for required in ["--emit-raw-deref-audit $@.rawderef.tsv",
                     "--emit-depfile $@.d",
                     "python3 scripts/measure_trusted_base.py --check-raw-deref el0 $@.rawderef.tsv $@.d"]:
        if required not in body:
            problems.append(f"KERNEL_EL0_COMPILE must contain {required}")
    for name in sorted(objects):
        prerequisites, recipe = rules[name]
        if "$(call KERNEL_EL0_COMPILE," not in recipe:
            problems.append(f"{name} must use KERNEL_EL0_COMPILE")
        if "KERNEL_RAW_DEREF_DEPS" not in prerequisites:
            problems.append(f"{name} must depend on KERNEL_RAW_DEREF_DEPS")
    dependencies = definitions.get("KERNEL_RAW_DEREF_DEPS", "").split()
    for required in ["Makefile", "scripts/measure_trusted_base.py", "scripts/raw_deref_budget.tsv"]:
        if required not in dependencies:
            problems.append(f"KERNEL_RAW_DEREF_DEPS must contain {required}")
    return objects, problems


def main():
    objects, problems = audit_recipe_problems((ROOT / "Makefile").read_text())
    if problems:
        raise SystemExit("\n".join("ERROR el0-raw-deref-audit: " + p for p in problems))
    report_pass("el0-raw-deref-audit",
                f"{len(objects)} standalone Takibi object rules emit and check their audits",
                objects=len(objects))


if __name__ == "__main__":
    main()
