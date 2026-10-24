#!/usr/bin/env python3
"""Fail the RPi5 lane when a parked issue's reopen condition is met.

GitHub issue #953. Some issues are parked (GitHub label `parked`) by the
maintainer until a measurement shows they matter. So that the discussion is
not forgotten, each one has a row in TRIGGERS below: the RECORDED boot line
that measures it, the measurement, and a threshold. When the measurement
passes the threshold, this script fails with a message naming the issue and
saying to reopen it. The issue numbers live in that table and nowhere else
in source. When an issue is resumed, remove its row (and, if nothing else
reads it, the counter behind it).

The RPi5 runner (scripts/run_kernel_hwtest_rpi5.sh) calls this with the
lane's UART log. QEMU timing is emulated, so neither trigger is judged there.
A missing or malformed line fails too: a trigger that cannot see its
measurement would otherwise stay silent forever.

Thresholds and their derivation:

#812, page_alloc_contiguous's linear run search (parked 2026-10-23, option
  (a): until a churn or long-running TCP workload shows max_ticks growing).
  Measurement: `RECORDED page run allocator: ... max_ticks=T ... freq=F`,
  the longest single IRQ-masked hold of the page lock inside
  page_alloc_contiguous (#771's counters), T / F seconds.
  Baseline: 819 ticks at 54 MHz = 15.2 us, the worst of the RPi5 runs
  recorded on #812 (issuecomment of 2026-10-23; other runs 528..534 ticks).
  Threshold: 3x baseline = 45.6 us, the factor the maintainer named.

#680, region_pool validation under the pool lock (parked 2026-10-23,
  option D: until a multicore TCP/fd workload shows the lock matters).
  Measurement: `RECORDED pool lock wait: <pool>=C ...`, per production
  pool the acquires C that found the lock already held
  (kernel/kernel/pool_lock_wait.tkb), outside the deliberate contention
  probes, summed across every pool. An absolute count over one bounded
  suite: the suite's workload is fixed, so its count moves only when the
  kernel's contention does. Only contended acquires are counted, so the
  uncontended lock path pays no counter (counting every acquire, for a
  share, cost 6.1 ns per lock pair on RPi5; #953).
  Baseline: five RPi5 kernelcheck boots on 2026-10-24 found 2739, 2517,
  2205, 1685 and 1342 contended acquires (process pool most, then
  address_space; every other pool 0-3). Baseline 2739, the highest.
  Threshold: 3x baseline = 8217, the same factor as #812. It rests on
  five runs; if an unchanged tree trips it, widen it from more runs
  rather than reopening #680.

Cost ceiling of the counter itself (#953): the #680 counter sits on every
production pool lock acquire, so its own cost must stay out of the hot
path. `RECORDED pool lock wait cost: pairs=N plain=P counted=C freq=F`
gives the least of three samples of N uncontended tcp_connection pool
lock/unlock pairs through the wrapper without the count (P) and through
the production wrapper (C). Fail when (C - P) / N / F exceeds
COUNTER_CEILING_NS. Measured 2026-10-24: +0.1..0.2 ns per pair (24.5 ns
pair); counting every acquire had cost +6.1 ns, an out-of-line held check
+2.6 ns. This is not a parked issue: it fails naming #953.

Controls: scripts/check_parked_triggers_controls.py.
"""

import argparse
import pathlib
import re
import sys

from pass_line import report_pass

# Contended production pool lock acquires per bounded suite, RPi5,
# 2026-10-24 (the highest of five runs).
BASELINE_680 = 2739

COUNTER_CEILING_NS = 1.0
COST_LINE = re.compile(
    r"RECORDED pool lock wait cost: pairs=(\d+) plain=(\d+) counted=(\d+) "
    r"freq=(\d+)\s*$")

PAGE_RUN_LINE = re.compile(
    r"RECORDED page run allocator: calls=\d+ visits=\d+ ticks=\d+ "
    r"max_ticks=(\d+) freq=(\d+)\s*$")
POOL_WAIT_LINE = re.compile(r"RECORDED pool lock wait:((?: \w+=\d+)+)\s*$")
POOL_WAIT_FIELD = re.compile(r"(\w+)=(\d+)")


class Unreadable(Exception):
    """The measurement is missing or malformed."""


def one_match(lines, pattern, what):
    """The single line matching `pattern`. The RPi5 log carries each RECORDED
    line twice (raw console and timestamped dmesg replay), with the same
    numbers, so distinct matches are what must be one."""
    found = {m.groups() for m in (pattern.search(l) for l in lines) if m}
    if not found:
        raise Unreadable(f"no `{what}` line")
    if len(found) > 1:
        raise Unreadable(f"{len(found)} different `{what}` lines")
    return found.pop()


def page_run_max_us(lines):
    ticks, freq = one_match(lines, PAGE_RUN_LINE, "RECORDED page run allocator:")
    if int(freq) == 0:
        raise Unreadable("RECORDED page run allocator: freq=0")
    return int(ticks) * 1e6 / int(freq), f"max_ticks={ticks} freq={freq}"


def pool_wait_contended(lines):
    (fields,) = one_match(lines, POOL_WAIT_LINE, "RECORDED pool lock wait:")
    pools = POOL_WAIT_FIELD.findall(fields)
    if not pools:
        raise Unreadable("RECORDED pool lock wait: no pool")
    contended = sum(int(c) for _, c in pools)
    return contended, f"contended={contended} over {len(pools)} pools"


# issue, what it is about, measurement, unit, threshold.
TRIGGERS = (
    (812, "page_alloc_contiguous linear run search",
     page_run_max_us, "us longest IRQ-masked page-lock hold", 3 * 15.2),
    (680, "region_pool validation under the pool lock",
     pool_wait_contended, "pool lock acquires that found it held per suite",
     3 * BASELINE_680),
)


def counter_cost(lines):
    """Failures of the #953 counter cost ceiling."""
    try:
        pairs, plain, counted, freq = (int(x) for x in one_match(
            lines, COST_LINE, "RECORDED pool lock wait cost:"))
    except Unreadable as error:
        return [f"FAIL pool-lock-counter-cost (#953): cannot read its "
                f"measurement ({error})"]
    if pairs == 0 or freq == 0 or plain == 0:
        return ["FAIL pool-lock-counter-cost (#953): pairs, plain or freq is 0"]
    extra_ns = (counted - plain) * 1e9 / freq / pairs
    if extra_ns > COUNTER_CEILING_NS:
        return [f"FAIL pool-lock-counter-cost (#953): the pool lock wait "
                f"count adds {extra_ns:.2f} ns per uncontended lock pair, over "
                f"{COUNTER_CEILING_NS} ns (plain={plain} counted={counted} "
                f"pairs={pairs} freq={freq}). Keep the uncontended path free "
                f"of counting (kernel/kernel/pool_lock_wait.tkb)."]
    return []


def evaluate(lines, triggers=TRIGGERS):
    """(failures, judged) for one log's lines."""
    failures = counter_cost(lines)
    for issue, about, measure, unit, threshold in triggers:
        try:
            value, detail = measure(lines)
        except Unreadable as error:
            failures.append(
                f"FAIL parked-trigger #{issue}: cannot read its measurement "
                f"({error}); a trigger that cannot see stays silent forever")
            continue
        if value > threshold:
            failures.append(
                f"FAIL parked-trigger #{issue} ({about}): {value:.4g} {unit} "
                f"exceeds the threshold {threshold:.4g} ({detail}). Its "
                f"reopen condition is met: reopen the discussion on GitHub "
                f"issue #{issue} (remove its `parked` label), and remove its "
                f"row from TRIGGERS in scripts/validate_parked_triggers.py "
                f"when work resumes.")
    return failures, len(triggers)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("uart_log", type=pathlib.Path)
    args = parser.parse_args(argv)
    lines = args.uart_log.read_bytes().decode("ascii", "replace").splitlines()
    failures, judged = evaluate(lines)
    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    report_pass("parked-triggers",
                f"{judged} parked issue trigger(s) read and below threshold",
                triggers=judged)
    return 0


if __name__ == "__main__":
    sys.exit(main())
