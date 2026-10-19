#!/usr/bin/env python3
"""Controls for ProcessRecord mint scope and destructive annotation retention."""

from control_patch import replace_once
from check_process_record_bare_uses import PATH, problems
from pass_line import report_pass


def main() -> int:
    source = PATH.read_text()
    assert not problems(source), "the production source must pass"
    inline_lookup = replace_once(source, "fn scheduled_process_record_locked(", "inline fn scheduled_process_record_locked(")
    assert not problems(inline_lookup), "an inline accessor must retain its body identity"
    controls = {
        "public view mint": replace_once(source, "private linear view ProcessCurrent[", "linear view ProcessCurrent["),
        "owner lookup restores raw escape": replace_once(source, "let record = scheduled_process_transfer_owned_loan(source, owner);", "let record = scheduled_process_record_at(owner.pool_index);"),
        # GitHub issue #845: the owned transfer's own marker. The bare
        # marker repeats, and its first copy was the locked transfer's.
        "owned transfer marker": replace_once(
            source,
            "destination: borrow ScheduledProcessOwner[process])\n"
            "        -> &mut ProcessRecord @ process !{unsafe, loan_transfer}",
            "destination: borrow ScheduledProcessOwner[process])\n"
            "        -> &mut ProcessRecord @ process !{unsafe}"),
        "public owned transfer": replace_once(source, "private inline fn scheduled_process_transfer_owned_loan(", "inline fn scheduled_process_transfer_owned_loan("),
        "slot removal marker": replace_once(source, "unsafe, record_mutates_ProcessRunGuard", "unsafe"),
        "reap removal marker": replace_once(source, "record_mutates_ScheduledProcessOwner", ""),
        "commented marker": replace_once(source, "record_mutates_ScheduledProcessOwner", "// record_mutates_ScheduledProcessOwner\n"),
        "public locked wrapper mint": replace_once(source, "private inline fn scheduled_process_locked_view_new(", "inline fn scheduled_process_locked_view_new("),
        "additional raw caller": source +
            "\nfn unreviewed() { scheduled_process_record_at(0); }\n",
        "additional ownership mint": source +
            "\nfn unreviewed() { scheduled_process_owner_new(0, 0); }\n",
        "public owner mint": replace_once(source, "private fn scheduled_process_owner_new(", "fn scheduled_process_owner_new("),
        "public running wrapper mint": replace_once(source, "private inline fn scheduled_process_current_view_new(", "inline fn scheduled_process_current_view_new("),
        "public running mint": replace_once(source, "private inline fn process_running_new(", "inline fn process_running_new("),
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
