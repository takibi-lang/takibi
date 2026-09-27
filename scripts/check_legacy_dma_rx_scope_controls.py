#!/usr/bin/env python3
"""Controls for the maintained legacy RX call boundary."""

from pathlib import Path
import sys

from check_legacy_dma_rx_scope import GEM, audit
from pass_line import CaseCount, report_pass

CASES = CaseCount()


def check_case(name: str, sources: dict[Path, str], want: str) -> list[str]:
    CASES.note()
    failures, _ = audit(sources)
    if not any(want in failure for failure in failures):
        return [f"{name}: missing rejection containing {want!r}: {failures!r}"]
    return []


def main() -> int:
    sources = {path: path.read_text(encoding="ascii")
               for path in sorted(Path("kernel").rglob("*.tkb"))}
    actual, calls = audit(sources)
    if actual or calls != 3:
        print(f"FAIL legacy-dma-rx controls: real tree: {actual!r}, calls={calls}",
              file=sys.stderr)
        return 1
    gem = sources[GEM]
    failures = []
    foreign = dict(sources)
    foreign[Path("kernel/drivers/block/virtio_blk.tkb")] += (
        "\nfn planted() { dma_finish_rx(buffer, 64); }\n")
    failures += check_case("foreign call", foreign, "outside the audited GEM buffer")
    after_string = dict(sources)
    after_string[Path("kernel/drivers/block/virtio_blk.tkb")] += (
        '\nfn planted() { log("http://device"); dma_finish_rx(buffer, 64); }\n')
    failures += check_case("call after quoted URL", after_string,
                           "outside the audited GEM buffer")
    changed = dict(sources)
    changed[GEM] = gem.replace("dma_prepare_rx(gem_rx_buf, RX_BUF_SIZE)",
                               "dma_prepare_rx(other_buf, RX_BUF_SIZE)", 1)
    failures += check_case("wrong GEM buffer", changed, "outside the audited GEM buffer")
    removed = dict(sources)
    removed[GEM] = gem.replace("dma_finish_rx(gem_rx_buf, RX_BUF_SIZE);", "", 1)
    failures += check_case("scan stopped looking", removed, "expected 1 call(s)")
    quoted = dict(sources)
    quoted[Path("kernel/drivers/block/virtio_blk.tkb")] += (
        '\nfn harmless() { log("dma_finish_rx(buffer, 64)"); }\n')
    CASES.note()
    quoted_failures, quoted_calls = audit(quoted)
    if quoted_failures or quoted_calls != 3:
        failures.append("quoted call: text inside a string was counted")
    if failures:
        for failure in failures:
            print("FAIL legacy-dma-rx controls: " + failure, file=sys.stderr)
        return 1
    report_pass("legacy-dma-rx controls",
                "real tree passes; foreign, changed, and missing calls are refused",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
