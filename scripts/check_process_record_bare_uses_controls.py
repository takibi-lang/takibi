#!/usr/bin/env python3
"""Controls for ProcessRecord mint scope and destructive annotation retention."""

from check_process_record_bare_uses import PATH, problems
from pass_line import report_pass


def main() -> int:
    source = PATH.read_text()
    assert not problems(source), "the production source must pass"
    controls = {
        "slot removal marker": source.replace(
            "unsafe, record_mutates_ProcessRunGuard", "unsafe", 1),
        "reap removal marker": source.replace(
            "record_mutates_ScheduledProcessOwner", "", 1),
        "commented marker": source.replace(
            "record_mutates_ScheduledProcessOwner",
            "// record_mutates_ScheduledProcessOwner\n", 1),
        "wrong raw caller with unchanged total": source.replace(
            "fn scheduled_process_record_locked(", "fn unreviewed_record_locked(", 1),
        "additional raw caller": source +
            "\nfn unreviewed() { scheduled_process_record_at(0); }\n",
        "additional ownership mint": source +
            "\nfn unreviewed() { scheduled_process_owner_new(0, 0); }\n",
        "public owner mint": source.replace(
            "private fn scheduled_process_owner_new(", "fn scheduled_process_owner_new(", 1),
        "public raw lookup": source.replace(
            "private fn scheduled_process_record_at(", "fn scheduled_process_record_at(", 1),
        "public running mint": source.replace(
            "private fn process_running_new(", "fn process_running_new(", 1),
    }
    for name, changed in controls.items():
        assert changed != source, f"control {name} did not change the input"
        assert problems(changed), f"control {name} was accepted"
    report_pass("process-record-bare-uses controls",
                f"production passes and {len(controls)} marker/mint regressions fail",
                controls=len(controls))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
