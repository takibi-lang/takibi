#!/usr/bin/env python3
"""A QMP client reads command replies only through qmp_wire.qmp_reply.

GitHub issues #879 and #880: QEMU may send an asynchronous event (RESUME,
STOP, ...) between a command and its reply. Clients that took the first line
after a command as the reply misread an accepted serial BREAK as a refusal and
emptied the postmortem walk (#871 repro run 2); the same one-line read sat in
four more clients. scripts/qmp_wire.py qmp_reply skips events.

So in every scripts/*.py function that negotiates QMP (it names
"qmp_capabilities"), no raw .readline()/.recv()/.read() call may follow the
first "qmp_capabilities" literal: the greeting (and any serial read) comes
before it, and every reply after it goes through qmp_reply. check_* files (whose fake QMP servers read requests) and
qmp_wire.py itself are exempt.

Exit code only (0 = pass, 1 = fail).
"""

import ast
import pathlib
import sys

from pass_line import report_pass

SCRIPTS = pathlib.Path("scripts")
HELPER = "qmp_wire.py"
RAW_READS = {"readline", "recv", "read"}


FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)


def own_nodes(function: ast.AST):
    """The function's nodes, not descending into nested functions; each is
    judged on its own."""
    stack = list(ast.iter_child_nodes(function))
    while stack:
        node = stack.pop()
        yield node
        if not isinstance(node, FUNCTIONS):
            stack.extend(ast.iter_child_nodes(node))


def first_capabilities(nodes):
    """Line of the first "qmp_capabilities" literal, or None."""
    lines = []
    for node in nodes:
        if isinstance(node, ast.Constant):
            value = node.value
            if isinstance(value, bytes):
                value = value.decode("latin-1")
            if isinstance(value, str) and "qmp_capabilities" in value:
                lines.append(node.lineno)
    return min(lines) if lines else None


def raw_reads(nodes) -> list[int]:
    return sorted(node.lineno for node in nodes
                  if isinstance(node, ast.Call)
                  and isinstance(node.func, ast.Attribute)
                  and node.func.attr in RAW_READS)


def violations(tree: ast.Module) -> list[int]:
    found = []
    scopes = [tree] + [node for node in ast.walk(tree)
                       if isinstance(node, FUNCTIONS)]
    for scope in scopes:
        nodes = list(own_nodes(scope))
        start = first_capabilities(nodes)
        if start is not None:
            found.extend(line for line in raw_reads(nodes) if line >= start)
    return found


def main() -> int:
    scanned = 0
    failures = []
    for path in sorted(SCRIPTS.glob("*.py")):
        if path.name.startswith("check_") or path.name == HELPER:
            continue
        text = path.read_text(encoding="utf-8")
        if "qmp_capabilities" not in text:
            continue
        scanned += 1
        for line in violations(ast.parse(text, str(path))):
            failures.append(f"{path}:{line}")
    if failures:
        for where in failures:
            print(f"ERROR\tqmp-reply-read: {where} reads a QMP reply raw; an "
                  "async event (RESUME, STOP) may arrive first and be taken "
                  "for the reply (#879, #880). Use qmp_wire.qmp_reply")
        print(f"FAIL qmp-reply-read: {len(failures)} site(s)")
        return 1
    if scanned == 0:
        print("FAIL qmp-reply-read: no QMP client found; the scan is broken")
        return 1
    report_pass("qmp-reply-read",
                "every QMP reply after the greeting is read through qmp_reply",
                files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
