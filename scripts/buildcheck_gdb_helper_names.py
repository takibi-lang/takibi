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
resolved type by type through the DWARF. So is a subscript on a Python
local assigned once from such a chain (execution =
gdb.parse_and_eval("execution_state")[cpu]; execution["current_handle"]),
through .dereference(), an index, or ARRAY_ITEM; a subscript whose base
type is not known must be a member of some struct in the ELF -- weaker,
but it still fails a rename or a removal.

GitHub issue #889 closed the run-time gaps. The Python is also parsed
(ast): an argument built from a loop name bound to a literal tuple (for
name in ("a", "b"), a comprehension, or a module constant tuple) -- "&" +
name, offset("WorldStop", name), f"...{name.upper()}..." -- is checked
once per value, and so is record[name]. Any other argument built at run
time must be a wrapper's own parameter (its call sites are checked), a "$"
register, or listed in DYNAMIC with a reason; an unlisted one fails, and so
does a DYNAMIC entry that no call matches any more. An f-string placeholder
that is not a loop name reads as 0.

Takibi enum, variant, case and constant names (takibi-enum,
takibi-force-variant-return, takibi-variant-layout, takibi-constant, and
kernel_state.gdb's _tk_enum, _tk_constant, _tk_named_constant) are looked
up in the --emit-debug-metadata JSON. RPi5 runners (those naming the RPi5
debug ELF) are checked with --rpi5 against that ELF, together with the
helpers they source, by the rule that links it; the QEMU run skips them.

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
           [--scripts DIR] [--rpi5] [--only FILE | --controls]
"""

import argparse
import ast
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
# kernel_debug_metadata.gdb's commands whose first word is a Takibi name.
TAKIBI_COMMANDS = {"takibi-enum", "takibi-constant", "takibi-variant-layout",
                   "takibi-force-variant-return"}

# Calls whose argument is built at run time from something this check
# cannot enumerate: per file, a pattern of the source line and why that
# argument names nothing a rename could break. A new such call fails until
# it is bound through a literal tuple loop or a constant, or listed here;
# an entry no call matches any more fails too.
DYNAMIC = {
    "kernel_debug_metadata.gdb": [
        (r"^value = _takibi_value\(expression\)$",
         "takibi-enum and takibi-constant evaluate the EXPRESSION their "
         "caller typed; each call site is checked as a command"),
    ],
    "gdb_progress.py": [
        (r"^gdb\.execute\(command\)$",
         "resume_slice's resume command (continue by default) from its "
         "callers; it names no kernel symbol"),
    ],
}

# Call kinds whose argument is a name in the debug metadata JSON.
METADATA_KINDS = TAKIBI_COMMANDS | {"takibi-constant-exact"}

# Helpers that return element `index` of a GDB array value.
ARRAY_ITEM = {"_tk_array_item"}

# Runners that drive the RPi5 board: their -ex commands, and the helpers
# they source, are checked against the RPi5 debug ELF (--rpi5) instead.
RPI5_ELF_MARK = "kernel/build/rpi5/kernel-debug.elf"

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
    def __init__(self, elf, metadata):
        self.elf = elf
        self.metadata = metadata
        self.metadata_keys = metadata_keys(metadata)
        self.errors = []
        self.names = 0
        self.dynamic_sites = 0
        self.dynamic_used = set()

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
        elif command in TAKIBI_COMMANDS:
            self.takibi_command(where, command, rest)
        elif command == "printf":
            parts = re.split(r'"(?:[^"\\]|\\.)*"\s*,?', rest, maxsplit=1)
            if len(parts) == 2:
                self.expression(where, parts[1])

    def takibi_command(self, where, command, rest):
        """kernel_debug_metadata.gdb's commands name Takibi enums,
        variants, cases and constants, which live in the compiler's
        --emit-debug-metadata JSON rather than in DWARF."""
        words = rest.split(None, 1)
        if not words or words[0] == "0":
            # An f-string placeholder: resolved, if it can be, by the
            # Python pass.
            return
        if self.metadata is None:
            self.fail(where, f"{command} names Takibi metadata; run this "
                      "check with --metadata")
            return
        type_name = words[0]
        rest = words[1] if len(words) > 1 else ""
        if command == "takibi-constant":
            self.names += 1
            if not any(item["name"].startswith(type_name)
                       for item in self.metadata["constants"]):
                self.fail(where, f"no Takibi constant starts with "
                          f"'{type_name}' in the debug metadata")
            self.expression(where, rest)
            return
        table = "enums" if command == "takibi-enum" else "variants"
        self.names += 1
        found = [item for item in self.metadata[table]
                 if item["name"] == type_name]
        if not found:
            self.fail(where, f"Takibi {table[:-1]} '{type_name}' is not "
                      "in the debug metadata")
            return
        if command == "takibi-enum":
            self.expression(where, rest)
        elif command == "takibi-force-variant-return":
            case = rest.split()[0] if rest.split() else ""
            if case and case != "0":
                self.names += 1
                if case not in {item["name"] for item in found[0]["cases"]}:
                    self.fail(where, f"case '{case}' is not a case of "
                              f"Takibi variant {type_name}")

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
                if re.match(r"\s*[+%]", text[match.end(2):]):
                    continue  # built at run time: the Python pass reads it
                if (kind in METADATA_KINDS
                        and re.search(r"\bf[\"']", argument)
                        and "{" in argument):
                    # A metadata name with a placeholder: "0" would be no
                    # name at all, so the Python pass resolves or lists it.
                    continue
                values = ["".join(_literal_text(item) for item in
                                  re.findall(_LITERAL, argument))]
            second =_literal_text(match.group(3).split(",", 1)[1].strip()) \
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
            if self.helper_key(name, key):
                continue
            self.member(where(match.start()), key)
        self.python_ast(where_prefix, first, text, calls, constants)

    def helper_key(self, file_name, key):
        """A subscript key that indexes something other than a kernel
        value: an ALL_CAPS environment variable or metadata constant, a
        key of the compiler's metadata JSON, or one HELPER_KEYS lists."""
        return bool(re.fullmatch(r"[A-Z][A-Z0-9_]*", key)) or \
            key in self.metadata_keys or \
            key in HELPER_KEYS.get(file_name, ())

    def python_ast(self, where_prefix, first, text, calls, constants):
        """What the literal pass cannot see: an argument built at run
        time (resolved through a literal tuple loop, a module constant or
        a wrapper's own parameter, else listed in DYNAMIC), and a value
        subscript whose base has a known DWARF type."""
        name = Path(where_prefix).name
        try:
            tree = ast.parse(text)
        except SyntaxError as error:
            self.fail(f"{where_prefix}:{first + (error.lineno or 1) - 1}",
                      f"Python does not parse: {error.msg}")
            return
        parents = {}
        for node in ast.walk(tree):
            for child in ast.iter_child_nodes(node):
                parents[child] = node
        source = text.splitlines()

        def where(node):
            return f"{where_prefix}:{first + node.lineno - 1}"

        def values(node):
            """The strings `node` can be, or None when it is built from
            something this check cannot enumerate."""
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                return [node.value]
            if isinstance(node, ast.Name):
                bound = _loop_values(node, parents, constants)
                if bound is not None:
                    return bound
                return constants.get(node.id)
            if isinstance(node, ast.JoinedStr):
                results = [""]
                for part in node.values:
                    if isinstance(part, ast.Constant):
                        results = [r + part.value for r in results]
                        continue
                    bound = placeholder(part.value)
                    if bound is None and metadata_kind:
                        return None  # "0" would be no name at all
                    # Any other placeholder reads as 0, as in the literal
                    # pass.
                    results = [r + o for r in results
                               for o in (bound or ["0"])]
                return results
            if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
                left = values(node.left)
                right = values(node.right)
                if left is None or right is None:
                    return None
                return [a + b for a in left for b in right]
            if isinstance(node, ast.IfExp):
                body = values(node.body)
                orelse = values(node.orelse)
                if body is None or orelse is None:
                    return None
                return body + orelse
            return None

        def gdb_own(node, kind):
            # "$" + name: a register or convenience variable, which is
            # GDB's own and names nothing in the kernel.
            return kind == "expression" and isinstance(node, ast.BinOp) \
                and isinstance(node.left, ast.Constant) \
                and node.left.value == "$"

        def placeholder(node):
            """A loop name, or its .upper() or .lower(): its strings."""
            change = None
            if isinstance(node, ast.Call) and not node.args and \
                    isinstance(node.func, ast.Attribute) and \
                    node.func.attr in ("upper", "lower"):
                change = node.func.attr
                node = node.func.value
            if not isinstance(node, ast.Name):
                return None
            bound = _loop_values(node, parents, constants)
            if bound is None or change is None:
                return bound
            return [getattr(value, change)() for value in bound]

        def loop_bound(node):
            return placeholder(node) is not None

        metadata_kind = False

        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not node.args:
                continue
            called = _dotted(node.func)
            if called not in calls:
                continue
            kind = calls[called]
            metadata_kind = kind in METADATA_KINDS
            argument = node.args[0]
            second = node.args[1] if len(node.args) > 1 else None
            # The literal pass reads a string literal, an f-string whose
            # placeholders are not loop names, and a constant named as a
            # location; everything else is resolved here or listed.
            literal = isinstance(argument, ast.Constant) or (
                isinstance(argument, ast.JoinedStr) and not any(
                    isinstance(part, ast.FormattedValue)
                    and (loop_bound(part.value) or metadata_kind)
                    for part in argument.values))
            if isinstance(argument, ast.Name) and kind == "location" and \
                    argument.id in constants and not loop_bound(argument):
                literal = True
            second_values = [None]
            if second is not None and kind == "layout" and \
                    not isinstance(second, ast.Constant):
                second_values = values(second)
                if second_values is None:
                    if not _wrapper_parameter(second, node, parents, calls):
                        self.dynamic(name, where(node),
                                     source[node.lineno - 1].strip())
                    second_values = [None]
            if literal and second_values == [None]:
                continue
            first_values = values(argument)
            if first_values is None:
                if gdb_own(argument, kind) or \
                        _wrapper_parameter(argument, node, parents, calls):
                    # A wrapper's body: its call sites carry the names,
                    # and they are checked there.
                    continue
                self.dynamic(name, where(node),
                             source[node.lineno - 1].strip())
                continue
            for value in first_values:
                for extra in second_values:
                    self.python_call(where(node), kind, value, extra)
        self.typed_subscripts(tree, parents, where, calls,
                              lambda node: _loop_values(node, parents,
                                                        constants),
                              name)

    def typed_subscripts(self, tree, parents, where, calls, loop_values,
                         file_name):
        """A value subscript reached from a local whose DWARF type is
        known: execution = gdb.parse_and_eval("execution_state")[cpu];
        execution["current_handle"] must be a member of that type."""
        expression_calls = {call for call, kind in calls.items()
                            if kind == "expression"}
        self._loop_values = loop_values
        self._file = file_name
        for scope in ast.walk(tree):
            if not isinstance(scope, (ast.Module, ast.FunctionDef)):
                continue
            body = [node for node in ast.walk(scope)
                    if _scope_of(node, parents) is scope]
            assigned = {}
            for node in body:
                if isinstance(node, (ast.Assign, ast.AugAssign,
                                     ast.AnnAssign, ast.For)):
                    targets = node.targets if isinstance(node, ast.Assign) \
                        else [node.target]
                    for target in targets:
                        for item in ast.walk(target):
                            if isinstance(item, ast.Name):
                                assigned[item.id] = assigned.get(item.id,
                                                                 0) + 1
            local_types = {}
            for node in sorted((n for n in body if isinstance(n, ast.Assign)),
                               key=lambda n: n.lineno):
                if len(node.targets) != 1 or not isinstance(
                        node.targets[0], ast.Name):
                    continue
                target = node.targets[0].id
                if assigned.get(target) != 1:
                    continue  # rebound: its type is not one thing
                typed = self.value_type(node.value, local_types,
                                        expression_calls, where, check=False)
                if typed is not None:
                    local_types[target] = typed
            for node in body:
                # The outermost subscript of each chain, checked once.
                if isinstance(node, ast.Subscript) and not (
                        isinstance(parents.get(node), ast.Subscript)
                        and parents[node].value is node):
                    self.value_type(node, local_types, expression_calls,
                                    where, check=True)

    def value_type(self, node, local_types, expression_calls, where, check):
        """The struct a GDB value expression has, checking each string
        subscript on the way when `check`; None when it is not known."""
        if isinstance(node, ast.Name):
            return local_types.get(node.id)
        if isinstance(node, ast.Call):
            called = _dotted(node.func)
            if called in expression_calls and node.args and isinstance(
                    node.args[0], ast.Constant) and isinstance(
                    node.args[0].value, str):
                return self.expression_type(node.args[0].value)
            if isinstance(node.func, ast.Attribute) and \
                    node.func.attr == "dereference" and not node.args:
                return self.value_type(node.func.value, local_types,
                                       expression_calls, where, check)
            if called in ARRAY_ITEM and node.args:
                # A helper's own element read: the array's element type.
                return self.value_type(node.args[0], local_types,
                                       expression_calls, where, check)
            return None
        if isinstance(node, ast.Subscript):
            base = self.value_type(node.value, local_types,
                                   expression_calls, where, check)
            key = node.slice
            if isinstance(key, ast.Constant) and isinstance(key.value, str):
                keys = [key.value]
            elif isinstance(key, ast.Name) and \
                    self._loop_values(key) is not None:
                # record[name] for name in ("cpu", "id", ...): each value
                # is a member read.
                keys = self._loop_values(key)
                if base is None and check:
                    for value in keys:
                        if not self.helper_key(self._file, value):
                            self.member(where(node), value)
            else:
                return base  # an index: the element type, already stripped
            fields = self.elf.structs.get(base) if base else None
            if fields is None:
                return None
            typed = None
            for value in keys:
                if check:
                    self.names += 1
                if value not in fields:
                    if check:
                        self.fail(where(node), f"field '{value}' is not a "
                                  f"member of {base}")
                    return None
                typed = _strip_type(fields[value])
            return typed if len(keys) == 1 else None
        return None

    def expression_type(self, text):
        """The struct a plain chain (root.member[index]->member) names,
        or None. *(struct T *)ADDRESS is a T."""
        cast = re.fullmatch(r"\s*\*\s*\(\s*(?:struct\s+)?([A-Za-z_][\w$]*)"
                            r"\s*\*\s*\).*", text)
        if cast and cast.group(1) in self.elf.structs:
            return cast.group(1)
        match = re.fullmatch(r"\s*([A-Za-z_]\w*)((?:\s*(?:\.|->)\s*\w+"
                             r"|\s*\[[^\]]*\])*)\s*", text)
        if not match:
            return None
        typed = _strip_type(self.elf.variables.get(match.group(1)))
        for step in re.findall(r"(?:\.|->)\s*(\w+)|\[[^\]]*\]",
                               match.group(2)):
            if typed is None:
                return None
            if step:
                typed = _strip_type(self.elf.structs.get(typed, {}).get(step))
        return typed

    def dynamic(self, file_name, where, line):
        """A call whose argument is built at run time: it must be one
        DYNAMIC lists, so the unchecked set cannot grow silently."""
        self.dynamic_sites += 1
        for index, (pattern, _reason) in enumerate(
                DYNAMIC.get(file_name, ())):
            if re.search(pattern, line):
                self.dynamic_used.add((file_name, index))
                return
        self.fail(where, "a name built at run time that this check cannot "
                  f"resolve: {line!r}; bind it through a literal tuple "
                  "loop or a constant, or list it in DYNAMIC with a reason")

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
        elif kind == "takibi-constant-exact":
            self.names += 1
            if self.metadata is None:
                self.fail(where, "a Takibi constant needs --metadata")
            elif value not in {item["name"]
                               for item in self.metadata["constants"]}:
                self.fail(where, f"Takibi constant '{value}' is not in the "
                          "debug metadata")
        elif kind in TAKIBI_COMMANDS:
            # A helper's own wrapper of the command: its first argument
            # is the command's first word.
            self.takibi_command(where, kind, value + " 0")
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


def _dotted(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        inner = _dotted(node.value)
        return None if inner is None else f"{inner}.{node.attr}"
    return None


def _scope_of(node, parents):
    node = parents.get(node)
    while node is not None and not isinstance(node, (ast.Module,
                                                     ast.FunctionDef)):
        node = parents.get(node)
    return node


def _literal_strings(node, constants):
    if isinstance(node, (ast.Tuple, ast.List)) and all(
            isinstance(item, ast.Constant) and isinstance(item.value, str)
            for item in node.elts):
        return [item.value for item in node.elts]
    if isinstance(node, ast.Name) and node.id in constants:
        return constants[node.id]
    return None


def _loop_values(name, parents, constants):
    """The strings `name` takes when an enclosing for loop or
    comprehension binds it to a literal tuple (or a module constant
    tuple), else None."""
    node = parents.get(name)
    while node is not None:
        if isinstance(node, ast.For) and isinstance(node.target, ast.Name) \
                and node.target.id == name.id:
            return _literal_strings(node.iter, constants)
        if isinstance(node, (ast.ListComp, ast.SetComp, ast.DictComp,
                             ast.GeneratorExp)):
            for generator in node.generators:
                if isinstance(generator.target, ast.Name) and \
                        generator.target.id == name.id:
                    return _literal_strings(generator.iter, constants)
        if isinstance(node, (ast.FunctionDef, ast.Lambda)):
            return None
        node = parents.get(node)
    return None


def _wrapper_parameter(argument, call, parents, calls):
    """True when the call sits in a def that is itself one of the checked
    calls and its argument reads only that def's parameters: the def is a
    wrapper, and its own call sites carry the names."""
    function = parents.get(call)
    while function is not None and not isinstance(function, ast.FunctionDef):
        function = parents.get(function)
    if function is None or function.name not in calls:
        return False
    parameters = {arg.arg for arg in function.args.args}
    names = {node.id for node in ast.walk(argument)
             if isinstance(node, ast.Name)}
    return bool(names) and names <= parameters


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
    "kernel_state.gdb": {"_tk_eval": "expression",
                         "_tk_enum": "takibi-enum",
                         "_tk_constant": "takibi-constant-exact",
                         "_tk_named_constant": "takibi-constant"},
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


def metadata_keys(metadata):
    """Every dict key anywhere in the compiler's debug-metadata JSON."""
    keys = set()
    if metadata is None:
        return keys

    def walk(value):
        if isinstance(value, dict):
            keys.update(value)
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(metadata)
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


# --controls for the #889 kinds, kept apart so each says which gap it
# closes. (file, original text, renamed text, word)
CONTROLS += [
    # A name reached only through a literal tuple loop ("&" + name, or
    # offset("WorldStop", name) for name in (...)).
    ("kernel_churn.gdb", '("claimed", "owner", "requested", "participants")',
     '("claimed", "owner_id", "requested", "participants")', "owner_id"),
    # A subscript on a local whose DWARF type is known: "pid" is a member
    # of other structs, so the any-struct rule alone would let it pass.
    ("kernel_peer_exit_check.py", 'execution["current_live"]',
     'execution["pid"]', "pid"),
    # A Takibi variant and case, which only the metadata JSON has.
    ("kernel_alloc_rollback.gdb",
     "takibi-force-variant-return AddressSpaceBackingReady Missing",
     "takibi-force-variant-return AddressSpaceBackingReady Absent",
     "Absent"),
    # A member read through a loop name (record[name] for name in ...).
    ("kernel_state.gdb", '("cpu", "id", "a", "b", "c", "d")',
     '("cpu", "ident", "a", "b", "c", "d")', "ident"),
    # A metadata constant built from a loop name in an f-string.
    ("kernel_state.gdb", '"peer_generation", "state", "wait_reason"',
     '"peer_gen", "state", "wait_reason"',
     "KERNEL_PROCESS_TRACE_PEER_GEN_WORD"),
    # A Takibi enum a helper's own wrapper names.
    ("kernel_state.gdb", "_tk_enum('UnifiedFdKind'",
     "_tk_enum('FdKind'", "FdKind"),
    ("kernel_exec_enomem_check.py",
     "takibi-force-variant-return PageAllocResult OutOfMemory",
     "takibi-force-variant-return PageAllocOutcome OutOfMemory",
     "PageAllocOutcome"),
]

# --rpi5 --controls: one rename in an RPi5 runner's -ex commands.
RPI5_CONTROLS = [
    ("run_kernel_ddb_rpi5_softwaretest.sh", '-ex "takibi-kernel 1"',
     '-ex "print kernel_secondary_boot_states"', "kernel_secondary_boot_states"),
]


def rpi5_runners(scripts):
    return [path for path in gdb_sources(scripts)
            if path.suffix in (".py", ".sh")
            and RPI5_ELF_MARK in path.read_text()]


def selected_sources(scripts, rpi5):
    """The QEMU debug ELF's helpers, or with `rpi5` the RPi5 runners and
    the .gdb helpers they source."""
    runners = rpi5_runners(scripts)
    if not rpi5:
        return [path for path in gdb_sources(scripts)
                if path.name not in OTHER_ELF and path not in runners]
    sourced = set()
    for path in runners:
        sourced.update(re.findall(r"source \S*?/scripts/(\w+\.gdb)",
                                  path.read_text()))
    return [scripts / name for name in sorted(sourced)] + runners


def run_check(elf, metadata, sources):
    checker = Checker(elf, metadata)
    for path in sources:
        check_file(checker, path)
    names = {path.name for path in sources}
    for file_name, entries in DYNAMIC.items():
        if file_name not in names:
            continue
        for index, (pattern, _reason) in enumerate(entries):
            if (file_name, index) not in checker.dynamic_used:
                checker.fail(file_name, f"DYNAMIC entry {pattern!r} matches "
                             "no call any more; remove it")
    return checker


def run_controls(elf, metadata, scripts, rpi5):
    names = [path.name for path in selected_sources(scripts, rpi5)]
    controls = RPI5_CONTROLS if rpi5 else CONTROLS
    failures = []
    with tempfile.TemporaryDirectory(prefix="gdb-helper-names-") as work:
        work = Path(work)
        for name in names:
            shutil.copy(scripts / name, work / name)
        sources = [work / name for name in names]
        baseline = run_check(elf, metadata, sources)
        if baseline.errors or baseline.names == 0:
            failures.append("the unrenamed copy does not pass: "
                            + "; ".join(baseline.errors))
        for file_name, original, renamed, word in controls:
            target = work / file_name
            text = (scripts / file_name).read_text()
            if text.count(original) != 1:
                failures.append(f"{file_name}: control text {original!r} "
                                "is not there exactly once; update CONTROLS")
                continue
            target.write_text(text.replace(original, renamed))
            checker = run_check(elf, metadata, sources)
            target.write_text(text)
            if not any(f"'{word}'" in error for error in checker.errors):
                failures.append(f"{file_name}: renaming {original!r} to "
                                f"{renamed!r} was not refused")
        # An unlisted run-time name, and a stale DYNAMIC entry, are refused.
        probe = work / names[0]
        text = probe.read_text()
        if probe.suffix == ".py" or "\npython\n" in text:
            DYNAMIC.setdefault(probe.name, []).append(
                (r"gdb-helper-names stale control", "control"))
            checker = run_check(elf, metadata, sources)
            DYNAMIC[probe.name].pop()
            if not any("matches no call" in error
                       for error in checker.errors):
                failures.append("a stale DYNAMIC entry was not refused")
        target = work / "kernel_churn.gdb"
        if target.exists():
            churn = target.read_text()
            target.write_text(churn.replace(
                'cell = address("asid_cell")',
                'cell = address(args[0] + "_cell")'))
            checker = run_check(elf, metadata, sources)
            target.write_text(churn)
            if not any("built at run time" in error
                       for error in checker.errors):
                failures.append("an unlisted run-time name was not refused")
    if failures:
        print("gdb-helper-names controls: FAIL", file=sys.stderr)
        for failure in failures:
            print("  " + failure, file=sys.stderr)
        return 1
    report_pass("gdb-helper-names-controls",
                f"{len(controls)} renames refused, the unrenamed copy passes"
                + ("" if rpi5 else ", run-time names must be listed"),
                controls=len(controls))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("elf")
    parser.add_argument("--metadata",
                        help="the compiler's --emit-debug-metadata JSON")
    parser.add_argument("--scripts",
                        default=str(Path(__file__).resolve().parent))
    parser.add_argument("--only", help="check this one helper file")
    parser.add_argument("--rpi5", action="store_true",
                        help="check the RPi5 runners against the RPi5 ELF")
    parser.add_argument("--controls", action="store_true",
                        help="rename names in a copy and require failure")
    args = parser.parse_args()
    metadata = None
    if args.metadata:
        with open(args.metadata, encoding="ascii") as stream:
            metadata = json.load(stream)
    if not args.only and metadata is None:
        parser.error("--metadata is required unless --only is given")
    elf = Elf(args.elf)
    scripts = Path(args.scripts)
    if args.controls:
        return run_controls(elf, metadata, scripts, args.rpi5)
    if args.only:
        sources = [scripts / args.only]
    else:
        sources = selected_sources(scripts, args.rpi5)
    checker = run_check(elf, metadata, sources)
    if checker.errors:
        print("gdb-helper-names: FAIL -- a GDB helper names what "
              f"{args.elf} does not have (GitHub issues #766, #889):",
              file=sys.stderr)
        for error in checker.errors:
            print("  " + error, file=sys.stderr)
        return 1
    report_pass("gdb-helper-names",
                f"{len(sources)} GDB helpers, {checker.names} names found "
                f"in {args.elf}, {checker.dynamic_sites} run-time names "
                "listed in DYNAMIC",
                files=len(sources), names=checker.names)
    return 0


if __name__ == "__main__":
    sys.exit(main())
