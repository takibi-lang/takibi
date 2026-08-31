#!/usr/bin/env python3
"""Keep the resumable DDB command surfaces synchronized with one inventory."""

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = {
    "inventory": ROOT / "kernel/DDB_COMMANDS.json",
    "source": ROOT / "kernel/arch/arm64/kernel/exception_evidence.tkb",
    "readme": ROOT / "kernel/README.md",
    "agents": ROOT / "AGENTS.md",
    "driver": ROOT / "scripts/run_kernel_ddb_driver.py",
}


def fail(surface: str, expected: list[str], actual: list[str]) -> None:
    missing = [item for item in expected if item not in actual]
    extra = [item for item in actual if item not in expected]
    details = []
    if missing:
        details.append("missing " + ", ".join(missing))
    if extra:
        details.append("extra " + ", ".join(extra))
    if not details:
        details.append("order differs")
    raise ValueError(f"DDB command drift in {surface}: {'; '.join(details)}")


def load_inventory(path: Path) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    data = json.loads(path.read_text(encoding="ascii"))
    public = data.get("public")
    hidden = data.get("hidden")
    if not isinstance(public, list) or not public:
        raise ValueError("DDB inventory public list is missing or empty")
    if not isinstance(hidden, list):
        raise ValueError("DDB inventory hidden list is missing")
    names = []
    for entry in public:
        if set(entry) != {"name", "usage", "coverage"}:
            raise ValueError(f"invalid public DDB inventory entry: {entry!r}")
        if entry["coverage"] != "qemu":
            raise ValueError(
                f"public DDB command {entry['name']} lacks focused integration coverage"
            )
        if entry["usage"].split()[0] != entry["name"]:
            raise ValueError(f"DDB usage does not start with its name: {entry!r}")
        names.append(entry["name"])
    for entry in hidden:
        if set(entry) != {"name", "classification", "reason", "coverage"}:
            raise ValueError(f"invalid hidden DDB inventory entry: {entry!r}")
        if entry["classification"] not in {"test-only", "display-only"}:
            raise ValueError(f"hidden DDB command lacks an explicit classification: {entry!r}")
        if entry["coverage"] != "qemu":
            raise ValueError(f"hidden DDB command lacks focused coverage: {entry!r}")
        if not entry["reason"]:
            raise ValueError(f"hidden DDB command lacks a documented reason: {entry!r}")
        names.append(entry["name"])
    if len(names) != len(set(names)):
        raise ValueError("DDB inventory contains duplicate command names")
    return public, hidden


def dispatcher_commands(text: str) -> list[str]:
    exact = re.findall(
        r"ddb_command_is\([^;]*?bs\"([a-z][a-z0-9]*)\"\)", text, re.DOTALL
    )
    prefixes = re.findall(
        r"ddb_command_starts_with\([^;]*?bs\"([a-z][a-z0-9]*) \"\)",
        text,
        re.DOTALL,
    )
    return list(dict.fromkeys(exact + prefixes))


def documented_inventories(text: str, surface: str) -> list[list[str]]:
    blocks = re.findall(
        r"<!-- DDB-COMMAND-INVENTORY-START -->(.*?)"
        r"<!-- DDB-COMMAND-INVENTORY-END -->",
        text,
        re.DOTALL,
    )
    if not blocks:
        raise ValueError(f"DDB command drift in {surface}: inventory block is missing")
    return [re.findall(r"`([^`]+)`", block) for block in blocks]


def driver_commands(text: str) -> list[str]:
    match = re.search(r"\n    commands = \[(.*?)\n    \]", text, re.DOTALL)
    if match is None:
        raise ValueError("DDB command drift in QEMU driver: commands list is missing")
    names = re.findall(r'(?:b|f)\"([a-z][a-z0-9]*)(?: |\\n)', match.group(1))
    return list(dict.fromkeys(names))


def check(paths: dict[str, Path]) -> None:
    public, hidden = load_inventory(paths["inventory"])
    public_names = [entry["name"] for entry in public]
    all_names = public_names + [entry["name"] for entry in hidden]
    usages = [entry["usage"] for entry in public]

    source = paths["source"].read_text(encoding="ascii")
    dispatched = dispatcher_commands(source)
    if set(dispatched) != set(all_names):
        fail("dispatcher", all_names, dispatched)

    expected_help = "commands: " + " ".join(usages) + r"\n"
    help_lines = re.findall(r'ddb_puts\("(commands: [^\"]+\\n)"\)', source)
    if help_lines != [expected_help]:
        fail("help", [expected_help], help_lines)

    for key, label in (("readme", "kernel/README.md"), ("agents", "AGENTS.md")):
        blocks = documented_inventories(
            paths[key].read_text(encoding="ascii"), label
        )
        for index, actual in enumerate(blocks, 1):
            if actual != usages:
                fail(f"{label} inventory block {index}", usages, actual)

    covered = driver_commands(paths["driver"].read_text(encoding="ascii"))
    if set(covered) != set(all_names):
        fail("QEMU integration driver", all_names, covered)


def main() -> int:
    parser = argparse.ArgumentParser()
    for name, default in DEFAULTS.items():
        parser.add_argument(f"--{name}", type=Path, default=default)
    args = parser.parse_args()
    try:
        check({name: getattr(args, name) for name in DEFAULTS})
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"FAIL ddb-command-inventory: {error}")
        return 1
    print("PASS ddb-command-inventory: dispatcher, help, docs, and coverage agree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
