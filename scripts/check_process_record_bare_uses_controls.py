#!/usr/bin/env python3
"""Controls for ProcessRecord mint scope and destructive annotation retention."""

from check_process_record_bare_uses import PATH, problems
from pass_line import report_pass


def main() -> int:
    source = PATH.read_text()
    assert not problems(source), "the production source must pass"
    inline_lookup = source.replace("fn scheduled_process_record_locked(",
                                   "inline fn scheduled_process_record_locked(", 1)
    assert not problems(inline_lookup), "an inline accessor must retain its body identity"
    controls = {
        "public view mint": source.replace(
            "private linear view ProcessCurrent[", "linear view ProcessCurrent[", 1),
        "owner lookup restores raw escape": source.replace(
            "let record = scheduled_process_transfer_owned_loan(live, owner);",
            "let record = scheduled_process_record_at(owner.pool_index);", 1),
        "owned transfer marker": source.replace(
            "unsafe, loan_transfer", "unsafe", 1),
        "public owned transfer": source.replace(
            "private inline fn scheduled_process_transfer_owned_loan(",
            "inline fn scheduled_process_transfer_owned_loan(", 1),
        "slot removal marker": source.replace(
            "unsafe, record_mutates_ProcessRunGuard", "unsafe", 1),
        "reap removal marker": source.replace(
            "record_mutates_ScheduledProcessOwner", "", 1),
        "commented marker": source.replace(
            "record_mutates_ScheduledProcessOwner",
            "// record_mutates_ScheduledProcessOwner\n", 1),
        "public locked wrapper mint": source.replace(
            "private inline fn scheduled_process_locked_view_new(", "inline fn scheduled_process_locked_view_new(", 1),
        "additional raw caller": source +
            "\nfn unreviewed() { scheduled_process_record_at(0); }\n",
        "additional ownership mint": source +
            "\nfn unreviewed() { scheduled_process_owner_new(0, 0); }\n",
        "public owner mint": source.replace(
            "private fn scheduled_process_owner_new(", "fn scheduled_process_owner_new(", 1),
        "public running wrapper mint": source.replace(
            "private inline fn scheduled_process_current_view_new(", "inline fn scheduled_process_current_view_new(", 1),
        "public running mint": source.replace(
            "private inline fn process_running_new(", "inline fn process_running_new(", 1),
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
