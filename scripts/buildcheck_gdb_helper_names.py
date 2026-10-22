#!/usr/bin/env python3
"""Reject a linked debug kernel whose GDB helpers name what it no longer has.

GitHub issue #766: scripts/kernel_peer_exit_check.py read
current_handle.pool_index.raw and struct IntrusiveSlot$ProcessRecord after
#745 had removed both, and nothing noticed until the one QEMU lane that runs
the script under GDB failed. The #786 extension adds functions: since the
kernel links with --gc-sections, a function only GDB calls or breaks on is
removed unless KERNEL_DEBUGGER_ENTRIES roots it.

This check reads the names the GDB helpers use and looks each one up in the
linked ELF handed to it (its DWARF via llvm-dwarfdump, its symbol table via
llvm-nm):

- the sources are scripts/*.gdb, every scripts/*.py that imports gdb, and
  the `-ex "command"` arguments every other runner script hands GDB (the
  runners drive the QEMU kernels, so this ELF is the one they name);
- GDB command text is the .gdb lines outside python blocks and the literal
  argument of gdb.execute(); break/tbreak/hbreak/until/advance name a
  symbol, and call/print/output/set var/x/printf/watch carry an expression;
- Python reads are the literal arguments of gdb.parse_and_eval (an
  expression), gdb.lookup_type (a type), gdb.lookup_global_symbol and
  gdb.lookup_symbol (a symbol), and every value["field"] subscript;
- in an expression, an identifier after "." or "->" is a struct member, an
  identifier after "struct" is a struct type, one followed by "*)" is a cast
  type, "$name" is GDB's own, and any other identifier is a root that must
  be a defined symbol of the ELF.

A member chain rooted at a global (execution_state.current_handle.x) is
resolved type by type through the DWARF; a member reached from a Python
local (execution["current_handle"]) cannot be typed here and must instead
be a member of some struct in the ELF -- weaker, but it still fails a rename
or a removal. An f-string placeholder reads as 0. A name built at run time
("&" + name) is not seen at all.

Not every subscript reads a kernel value. A key the compiler's
--emit-debug-metadata JSON uses (read from the metadata file handed in, so
the set follows the compiler) indexes that JSON; an ALL_CAPS key is an
environment variable or a metadata constant; HELPER_KEYS lists, per file,
the keys of a helper's own dicts, so that waiver cannot grow silently.

stall_probe.gdb reads symbols only the race-window kernels define, and
debug_return_abi.gdb breaks in a fixture of its own, so the debug-kernel
run skips the files in OTHER_ELF and the rule that links each of those
ELFs runs this check with --only.

Usage: buildcheck_gdb_helper_names.py <elf> [--metadata JSON]
           [--scripts DIR] [--only FILE | --controls]
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from pass_line import report_pass


LLVM_DWARFDUMP = "llvm-dwarfdump-19"
LLVM_NM = "llvm-nm-19"

# Subscript keys of a helper's own Python dicts, not a kernel value: the
# file, then the keys it may use.
HELPER_KEYS = {
    # takibi-churn's per-sample record, built from WorldStop's words.
    "kernel_churn.gdb": {"acks", "owner_cpu", "asid_next"},
}

# Helpers written against another kernel than the debug ELF, and the rule
# that checks them instead.
OTHER_ELF = {
    "stall_probe.gdb": "the race-window ELF rule (--only stall_probe.gdb)",
    "debug_return_abi.gdb": "scripts/run_kernel_debug_return_abi_qemutest.sh "
                            "(--only debug_return_abi.gdb on its fixture)",
}

BREAK_COMMANDS = {"break", "b", "tbreak", "hbreak", "thbreak", "until",
                  "advance", "rbreak"}
EXPRESSION_COMMANDS = {"call", "print", "p", "output", "x", "display",
                       "watch", "rwatch", "awatch", "ptype", "whatis"}
C_TYPE_WORDS = {"sizeof", "unsigned", "signed", "long", "int", "char",
                "short", "void", "struct", "union", "enum", "const",
                "volatile", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                "int8_t", "int16_t", "int32_t", "int64_t"}


class Elf:
    def __init__(self, path):
        self.structs = {}
        self.variables = {}
        self.members = set()
        self.base_types = set()
        self.locals = {}
        self._read_dwarf(path)
        nm = subprocess.run([LLVM_NM, "--defined-only", path], check=True,
                            capture_output=True, text=True).stdout
        self.symbols = {line.split()[-1] for line in nm.splitlines()
                        if len(line.split()) >= 3}

    def _read_dwarf(self, path):
        text = subprocess.run([LLVM_DWARFDUMP, "--debug-info", path],
                              check=True, capture_output=True,
                              text=True).stdout
        tag_re = re.compile(r"^0x[0-9a-f]+:( +)(DW_TAG_\w+)")
        attr_re = re.compile(r"^ +(DW_AT_\w+)\t\((.*)\)$")
        stack = []  # (indent, tag, attrs)
        entries = []
        for line in text.splitlines():
            match = tag_re.match(line)
            if match:
                entry = [len(match.group(1)), match.group(2), {}, None]
                while stack and stack[-1][0] >= entry[0]:
                    stack.pop()
                entry[3] = stack[-1] if stack else None
                stack.append(entry)
                entries.append(entry)
                continue
            match = attr_re.match(line)
            if match and stack:
                stack[-1][2].setdefault(match.group(1), match.group(2))
        for _indent, tag, attrs, parent in entries:
            name = _quoted(attrs.get("DW_AT_name"))
            if name is None:
                continue
            if tag == "DW_TAG_structure_type":
                self.structs.setdefault(name, {})
            elif tag == "DW_TAG_base_type":
                self.base_types.add(name)
            elif tag == "DW_TAG_member" and parent is not None \
                    and parent[1] == "DW_TAG_structure_type":
                owner = _quoted(parent[2].get("DW_AT_name"))
                self.members.add(name)
                if owner is not None:
                    self.structs.setdefault(owner, {})[name] = \
                        _quoted(attrs.get("DW_AT_type"), last=True)
            elif tag in ("DW_TAG_formal_parameter", "DW_TAG_variable") \
                    and parent is not None \
                    and parent[1] == "DW_TAG_subprogram":
                function = _quoted(parent[2].get("DW_AT_name"))
                if function is not None:
                    self.locals.setdefault(function, set()).add(name)
            elif tag == "DW_TAG_variable" and parent is not None \
                    and parent[1] == "DW_TAG_compile_unit":
                self.variables[name] = _quoted(attrs.get("DW_AT_type"),
                                               last=True)

    def has_type(self, name):
        name = name.strip()
        while name.endswith("*"):
            name = name[:-1].strip()
        return (name in self.structs or name in self.base_types
                or name in C_TYPE_WORDS
                or all(word in C_TYPE_WORDS for word in name.split()))


def _quoted(value, last=False):
    if value is None:
        return None
    found = re.findall(r'"((?:[^"\\]|\\.)*)"', value)
    if not found:
        return None
    return found[-1] if last else found[0]


def _strip_type(type_name):
    """The struct a value of DWARF type `type_name` exposes members of,
    after one level of array or pointer, or None."""
    if type_name is None:
        return None
    type_name = type_name.strip()
    match = re.fullmatch(r"\[(.*); [^\]]*\]", type_name)
    if match:
        type_name = match.group(1).strip()
    while type_name.endswith("*"):
        type_name = type_name[:-1].strip()
    return type_name


class Checker:
    def __init__(self, elf, metadata_keys):
        self.elf = elf
        self.metadata_keys = metadata_keys
        self.errors = []
        self.names = 0

    def fail(self, where, message):
        self.errors.append(f"{where}: {message}")

    def symbol(self, where, name):
        self.names += 1
        if name not in self.elf.symbols:
            self.fail(where, f"symbol '{name}' is not defined in the ELF")

    def type_name(self, where, name):
        self.names += 1
        if not self.elf.has_type(name):
            self.fail(where, f"type '{name}' is not in the ELF's DWARF")

    def member(self, where, name):
        self.names += 1
        if name not in self.elf.members:
            self.fail(where,
                      f"field '{name}' is a member of no struct in the ELF")

    def expression(self, where, text, function=None):
        text = re.sub(r'"(?:[^"\\]|\\.)*"', '""', text)
        text = re.sub(r"'(?:[^'\\]|\\.)*'", "''", text)
        token_re = re.compile(
            r"\$\w+|->|[A-Za-z_][\w$]*|0[xX][0-9a-fA-F]+|\d+|\S")
        tokens = token_re.findall(text)
        index = 0
        chain_type = None
        while index < len(tokens):
            token = tokens[index]
            before = tokens[index - 1] if index > 0 else ""
            after = tokens[index + 1] if index + 1 < len(tokens) else ""
            if not re.fullmatch(r"[A-Za-z_][\w$]*", token):
                if token not in (".", "->", "[", "]") and not \
                        re.fullmatch(r"\w+", token):
                    chain_type = None
                if token == "[":
                    depth = 0
                    while index < len(tokens):
                        if tokens[index] == "[":
                            depth += 1
                        elif tokens[index] == "]":
                            depth -= 1
                            if depth == 0:
                                break
                        index += 1
                    chain_type = _strip_type(chain_type)
                index += 1
                continue
            if before in (".", "->"):
                if chain_type is not None and chain_type in self.elf.structs:
                    self.names += 1
                    fields = self.elf.structs[chain_type]
                    if token not in fields:
                        self.fail(where, f"field '{token}' is not a member "
                                  f"of {chain_type}")
                        chain_type = None
                    else:
                        chain_type = _strip_type(fields[token])
                else:
                    self.member(where, token)
                    chain_type = None
            elif before in ("struct", "union", "enum"):
                self.type_name(where, token)
                chain_type = None
            elif token in C_TYPE_WORDS:
                chain_type = None
            elif after == "*" or (after == ")" and before == "("):
                # A cast: (ProcessRecord *) or (usize).
                self.type_name(where, token)
                chain_type = None
            elif function is not None and \
                    token in self.elf.locals.get(function, ()):
                # A breakpoint condition reads the stopped function's own
                # parameters and locals.
                self.names += 1
                chain_type = None
            else:
                self.symbol(where, token)
                chain_type = _strip_type(self.elf.variables.get(token))
            index += 1

    def command(self, where, line):
        line = line.strip()
        if not line or line.startswith("#"):
            return
        words = line.split(None, 1)
        command = words[0].split("/")[0]
        rest = words[1] if len(words) > 1 else ""
        if command in BREAK_COMMANDS:
            location = rest.split()[0].lstrip("*") if rest.split() else ""
            self.location(where, location)
            if " if " in f" {rest} ":
                self.expression(where, rest.split(" if ", 1)[1],
                                function=location)
        elif command in EXPRESSION_COMMANDS:
            self.expression(where, rest)
        elif command == "set" and rest.split(None, 1)[:1] in (["var"],
                                                             ["variable"]):
            self.expression(where, rest.split(None, 1)[1])
        elif command == "set" and "=" in rest:
            # set *(unsigned long *)&name = 3, set $x = expr; a GDB
            # setting (set confirm off) has no "=".
            self.expression(where, rest)
        elif command in ("if", "while"):
            self.expression(where, rest)
        elif command == "printf":
            parts = re.split(r'"(?:[^"\\]|\\.)*"\s*,?', rest, maxsplit=1)
            if len(parts) == 2:
                self.expression(where, parts[1])

    def python(self, where_prefix, lines):
        name = Path(where_prefix).name
        calls = dict(CALLS)
        calls.update(WRAPPERS.get(name, {}))
        first = lines[0][0] if lines else 1
        text = "\n".join(line for _number, line in lines)

        def where(offset):
            return f"{where_prefix}:{first + text.count(chr(10), 0, offset)}"

        # Module constants a breakpoint may be named through:
        # PEER_WINDOW = "symbol" or PEER_PARKS = ("a", "b").
        constants = {}
        for match in re.finditer(
                r"^([A-Z][A-Z0-9_]*)\s*=\s*(\(?\s*(?:" + _LITERAL
                + r"\s*,?\s*)+\)?)\s*$", text, re.M):
            constants[match.group(1)] = [
                _literal_text(item)
                for item in re.findall(_LITERAL, match.group(2))]
        call_re = re.compile(
            r"(?<![\w.])(" + "|".join(re.escape(call) for call in calls)
            + r")\(\s*((?:" + _LITERAL + r"\s*)+|[A-Z][A-Z0-9_]*\b)"
            r"(\s*,\s*(?:" + _LITERAL + r"))?")
        for match in call_re.finditer(text):
            kind = calls[match.group(1)]
            argument = match.group(2)
            if re.fullmatch(r"[A-Z][A-Z0-9_]*", argument):
                values = constants.get(argument)
                if values is None or kind != "location":
                    continue
            else:
                values = ["".join(_literal_text(item) for item in
                                  re.findall(_LITERAL, argument))]
            second = _literal_text(match.group(3).split(",", 1)[1].strip()) \
                if match.group(3) else None
            for value in values:
                self.python_call(where(match.start()), kind, value, second)
        for parks in re.finditer(
                r"gdb\.Breakpoint\(\s*(\w+)\s*\)\s*for\s+(\w+)\s+in\s+"
                r"([A-Z][A-Z0-9_]*)\b", text):
            if parks.group(1) == parks.group(2):
                for value in constants.get(parks.group(3), ()):
                    self.python_call(where(parks.start()), "location",
                                     value, None)
        for match in re.finditer(r"\[\s*\"([A-Za-z_]\w*)\"\s*\]", text):
            key = match.group(1)
            if re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
                # An environment variable or a compiler metadata
                # constant: neither is a kernel struct member.
                continue
            if key in self.metadata_keys or key in HELPER_KEYS.get(name, ()):
                continue
            self.member(where(match.start()), key)

    def python_call(self, where, kind, value, second):
        if kind == "expression":
            self.expression(where, value)
        elif kind == "type":
            self.type_name(where, re.sub(r"^struct\s+", "", value))
        elif kind == "command":
            self.command(where, value)
        elif kind == "symbol":
            self.symbol(where, value)
        elif kind == "location":
            self.location(where, value.lstrip("*"))
        elif kind == "layout":
            # offset/layout(struct, field): the struct-layout file's
            # "size" pseudo-field is the struct's own size.
            self.type_name(where, value)
            if second is not None and second != "size":
                self.names += 1
                if second not in self.elf.structs.get(value, {}):
                    self.fail(where, f"field '{second}' is not a member "
                              f"of {value}")
        elif isinstance(kind, tuple) and kind[0] == "member-of":
            self.names += 1
            if value not in self.elf.structs.get(kind[1], {}):
                self.fail(where, f"field '{value}' is not a member of "
                          f"{kind[1]}")

    def location(self, where, location):
        if re.fullmatch(r"[A-Za-z_][\w$]*", location):
            self.symbol(where, location)


_LITERAL = r"""f?(?:"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')"""


def _literal_text(literal):
    """The text of one Python string literal, an f-string's placeholders
    read as 0."""
    literal = literal.strip()
    is_f = literal.startswith("f")
    body = literal[2:-1] if is_f else literal[1:-1]
    if is_f:
        body = re.sub(r"\{[^}]*\}", "0", body)
    return body


# The calls whose literal argument names something in the kernel, and what
# that argument is.
CALLS = {
    "gdb.parse_and_eval": "expression",
    "gdb.lookup_type": "type",
    "gdb.lookup_global_symbol": "symbol",
    "gdb.lookup_symbol": "symbol",
    "gdb.lookup_static_symbol": "symbol",
    "gdb.execute": "command",
    "gdb.Breakpoint": "location",
}

# A helper's own wrappers around those calls, per file.
WRAPPERS = {
    "kernel_state.gdb": {"_tk_eval": "expression"},
    "kernel_debug_metadata.gdb": {"_takibi_value": "expression"},
    "kernel_churn.gdb": {"address": "symbol", "offset": "layout"},
    "kernel_console.gdb": {"address": "symbol", "word": "symbol",
                           "atomic": "symbol", "layout": "layout",
                           "field": ("member-of", "KernelLogCoreState")},
}


def gdb_sources(scripts):
    """The GDB helpers: *.gdb, every script that imports gdb, and every
    other runner that hands GDB a command with -ex (checks under
    scripts/check_* and this file are not helpers)."""
    sources = sorted(scripts.glob("*.gdb"))
    for path in sorted(list(scripts.glob("*.py")) + list(scripts.glob("*.sh"))):
        if path.name.startswith(("check_", "buildcheck_gdb_helper_names")):
            continue
        text = path.read_text()
        if re.search(r"^\s*import gdb\s*$", text, re.M) or \
                _EX_RE.search(text):
            sources.append(path)
    return sources


_EX_RE = re.compile(r"""-ex\s+("(?:[^"\\]|\\.)*"|'[^']*')""")


def check_runner(checker, path, text):
    """A runner's `gdb -ex "command"` arguments. A shell or f-string
    expansion reads as a GDB convenience variable, which names nothing."""
    for match in _EX_RE.finditer(text):
        command = match.group(1)[1:-1]
        command = re.sub(r"\$\{?\w+\}?", "$x", command)
        command = re.sub(r"\{[^}]*\}", "$x", command)
        checker.command(f"{path}:{text.count(chr(10), 0, match.start()) + 1}",
                        command)


def check_file(checker, path):
    text = path.read_text()
    lines = text.splitlines()
    numbered = list(enumerate(lines, start=1))
    if path.suffix in (".py", ".sh"):
        check_runner(checker, path, text)
    if path.suffix == ".sh":
        return
    if path.suffix == ".py":
        if re.search(r"^\s*import gdb\s*$", text, re.M):
            checker.python(str(path), numbered)
        return
    python_block = []
    in_python = False
    for number, line in numbered:
        stripped = line.strip()
        if in_python:
            if stripped == "end" and not line.startswith((" ", "\t")):
                checker.python(str(path), python_block)
                python_block = []
                in_python = False
            else:
                python_block.append((number, line))
            continue
        if stripped in ("python", "python-interactive"):
            in_python = True
            continue
        checker.command(f"{path}:{number}", stripped)
    if python_block:
        checker.python(str(path), python_block)


def metadata_keys(path):
    """Every dict key anywhere in the compiler's debug-metadata JSON."""
    keys = set()

    def walk(value):
        if isinstance(value, dict):
            keys.update(value)
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    with open(path, encoding="ascii") as stream:
        walk(json.load(stream))
    return keys


# --controls: one rename of each kind the check reads, applied to a copy of
# the helpers. Each must fail the check naming the renamed word; the
# unrenamed copy must pass. (file, original text, renamed text, word)
CONTROLS = [
    # #745's shape: a member read through a Python value subscript.
    ("kernel_peer_exit_check.py", '["pool_index"]', '["pool_slot"]',
     "pool_slot"),
    # A member chain rooted at a global, resolved type by type: "pid" is a
    # member of other structs, but not of the snapshot.
    ("kernel_state.gdb", '"ddb_snapshot.sequence"', '"ddb_snapshot.pid"',
     "pid"),
    ("kernel_peer_exit_check.py", '"struct ProcessRecord"',
     '"struct IntrusiveSlot$ProcessRecord"', "IntrusiveSlot$ProcessRecord"),
    ("kernel_peer_exit_check.py", 'parse_and_eval("execution_state")',
     'parse_and_eval("execution_states")', "execution_states"),
    ("kernel_alloc_rollback.gdb", "break page_alloc_contiguous ",
     "break page_alloc_run ", "page_alloc_run"),
    ("kernel_alloc_rollback.gdb", "if (int)owner == 5",
     "if (int)owner_tag == 5", "owner_tag"),
    ("kernel_churn.gdb", 'offset("AsidState", "next")',
     'offset("AsidState", "next_asid")', "next_asid"),
    ("kernel_uart_wake_check.py", 'gdb.Breakpoint("timer_irq_handler")',
     'gdb.Breakpoint("timer_irq_entry")', "timer_irq_entry"),
    # #786's shape: a debugger-only function a runner calls by name.
    ("run_kernel_oops_qemutest.sh", "call (void) kernel_process_trace_report()",
     "call (void) kernel_process_trace_dump()", "kernel_process_trace_dump"),
]


def run_check(elf, keys, sources):
    checker = Checker(elf, keys)
    for path in sources:
        check_file(checker, path)
    return checker


def run_controls(elf, keys, scripts):
    names = [path.name for path in gdb_sources(scripts)
             if path.name not in OTHER_ELF]
    failures = []
    with tempfile.TemporaryDirectory(prefix="gdb-helper-names-") as work:
        work = Path(work)
        for name in names:
            shutil.copy(scripts / name, work / name)
        sources = [work / name for name in names]
        baseline = run_check(elf, keys, sources)
        if baseline.errors or baseline.names == 0:
            failures.append("the unrenamed copy does not pass: "
                            + "; ".join(baseline.errors))
        for file_name, original, renamed, word in CONTROLS:
            target = work / file_name
            text = (scripts / file_name).read_text()
            if text.count(original) != 1:
                failures.append(f"{file_name}: control text {original!r} "
                                "is not there exactly once; update CONTROLS")
                continue
            target.write_text(text.replace(original, renamed))
            checker = run_check(elf, keys, sources)
            target.write_text(text)
            if not any(f"'{word}'" in error for error in checker.errors):
                failures.append(f"{file_name}: renaming {original!r} to "
                                f"{renamed!r} was not refused")
    if failures:
        print("gdb-helper-names controls: FAIL", file=sys.stderr)
        for failure in failures:
            print("  " + failure, file=sys.stderr)
        return 1
    report_pass("gdb-helper-names-controls",
                f"{len(CONTROLS)} renames refused, the unrenamed copy passes",
                controls=len(CONTROLS))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("elf")
    parser.add_argument("--metadata",
                        help="the compiler's --emit-debug-metadata JSON")
    parser.add_argument("--scripts",
                        default=str(Path(__file__).resolve().parent))
    parser.add_argument("--only", help="check this one helper file")
    parser.add_argument("--controls", action="store_true",
                        help="rename names in a copy and require failure")
    args = parser.parse_args()
    keys = metadata_keys(args.metadata) if args.metadata else set()
    if not args.only and not keys:
        parser.error("--metadata is required unless --only is given")
    elf = Elf(args.elf)
    scripts = Path(args.scripts)
    if args.controls:
        return run_controls(elf, keys, scripts)
    if args.only:
        sources = [scripts / args.only]
    else:
        sources = [path for path in gdb_sources(scripts)
                   if path.name not in OTHER_ELF]
    checker = run_check(elf, keys, sources)
    if checker.errors:
        print("gdb-helper-names: FAIL -- a GDB helper names what "
              f"{args.elf} does not have (GitHub issue #766):",
              file=sys.stderr)
        for error in checker.errors:
            print("  " + error, file=sys.stderr)
        return 1
    report_pass("gdb-helper-names",
                f"{len(sources)} GDB helpers, {checker.names} names found "
                f"in {args.elf}",
                files=len(sources), names=checker.names)
    return 0


if __name__ == "__main__":
    sys.exit(main())
