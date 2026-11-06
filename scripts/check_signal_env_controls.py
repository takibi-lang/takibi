#!/usr/bin/env python3
"""GitHub issue #1392: the signal-environment line decodes /proc masks right."""
from pass_line import report_pass
import signal_env

cases = signal_env.controls()
report_pass("signal-env controls", f"{cases} planted /proc masks decoded", cases=cases)
