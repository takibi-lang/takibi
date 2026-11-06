#!/usr/bin/env python3
"""GitHub issue #1391: the untracked-leak report compares its lists right."""
import sys

import untracked_leaks

sys.exit(untracked_leaks.main(["--controls"]))
