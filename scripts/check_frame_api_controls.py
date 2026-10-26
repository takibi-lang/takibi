#!/usr/bin/env python3
"""Negative controls for check_frame_api.py (GitHub issue #1018)."""

from check_frame_api import RATCHET, load, mint_files, problems
from pass_line import report_pass

# The control file is taken from the mint list rather than named: a fixed
# name broke this control when that file left the list (#637, 2026-10-26).
SHRUNK = "kernel/drivers/net/rp1_gem.tkb"


def main():
    sources, mint_text = load()
    PATH = next(path for path in mint_files(mint_text) if path != SHRUNK)
    assert not problems(sources, mint_text)[0], "production passes"
    original = sources[PATH]
    planted = {
        "raw pointer": "\nfn unreviewed() -> *u8 { return 0 as *u8; }\n",
        "io pointer": "\nfn unreviewed() -> *io u32 { return 0 as *io u32; }\n",
        "pointer in tuple": "\nfn unreviewed() -> (bool, *u8) !{unsafe} { }\n",
        "wrapped signature": "\ninline fn unreviewed(\n    a: usize)\n    -> *align(8) u64 { }\n",
        "named address": "\nfn block_buffer_address() -> usize { return 0; }\n",
        "refined address": "\nfn block_physical(i: {0..<4 as usize}) -> {0..<8 as usize} { }\n",
    }
    for name, text in planted.items():
        assert problems({**sources, PATH: original + text}, mint_text)[0], name
    allowed = {
        "private pointer": "\nprivate fn unreviewed() -> *u8 { }\n",
        "plain count": "\nfn block_unreviewed_count() -> usize { return 0; }\n",
        "pointer parameter": "\nfn unreviewed(p: *u8) -> bool { }\n",
        "comment": "\n// fn unreviewed() -> *u8 { }\n",
    }
    for name, text in allowed.items():
        assert not problems({**sources, PATH: original + text}, mint_text)[0], name
    # A ratchet entry whose function is gone is stale.
    stale = {**RATCHET, (PATH, "block_gone_address"): ("#637", "control")}
    assert problems(sources, mint_text, stale)[0], "stale entry"
    # A file that leaves the mint list takes its entries' staleness with it.
    shrunk = mint_text.replace(SHRUNK + "\n", "")
    assert shrunk != mint_text
    assert problems(sources, shrunk)[0], "entry for an unlisted file"
    # A mint file that is listed but absent is refused, not skipped.
    missing = {key: value for key, value in sources.items() if key != PATH}
    assert problems(missing, mint_text)[0], "missing mint file"
    count = len(planted) + 3
    report_pass("frame-api controls",
                f"production passes, {count} regressions fail, "
                f"{len(allowed)} non-violations pass",
                controls=count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
