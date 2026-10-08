"""Shared final predicates for live and retained QEMU DDB captures.

These are evidence checks, not a replay of interrupt timing or the live GDB
comparison. The software backtrace predicates remain shared with RPi5.
"""

import re
from ddb_software_brk_checks import backtrace_problems

SIGNALS = (r"(none|(sigint|sigquit|sigterm|sigchld|sigtstp)"
           r"(,(sigint|sigquit|sigterm|sigchld|sigtstp))*"
           r"(\+0x[0-9a-f]{16})?|0x[0-9a-f]{16})")

# name, expression, minimum count, maximum count, applicable BREAK source.
# Entries are kept in the old shell chain's order for reviewability.
REQUIREMENTS = (
    ('debugger banner', '^ddb: interrupt-safe UART debugger$', 1, None, 'both'),
    ('world stop acknowledgement', '^ddb: world-stop complete mask=0x0000000000000002$', 1, None, 'both'),
    ('BREAK frame', '^ddb: break seq=[1-9][0-9]* cpu=[0-9]+ elr=0x[0-9a-f]+ sp_el0=0x[0-9a-f]+$', 1, None, 'both'),
    ('register x0', '^ddb: x0=0x', 1, None, 'both'),
    ('register sp_el0', '^ddb: sp_el0=0x', 1, None, 'both'),
    ('interrupt entry and source', '^ddb: intr cpu=[0-9]+ entry={entry} source={source} live_daif=0x[0-9a-f]+ saved_daif=0x[0-9a-f]+$', 1, None, 'both'),
    ('interrupt fault registers', '^ddb: intr esr=(0x[0-9a-f]+|unavailable) far=(0x[0-9a-f]+|unavailable)$', 1, None, 'both'),
    # GitHub issue #715: the boot fixture raised SGI 2 on CPU 1 eight times,
    # each after the last was counted. capture_problems refuses a count of it
    # on CPU 0, which never took it.
    ('fixture SGI counted on CPU 1', '^ddb: intr count cpu=1 intid=2 count=8$', 1, 1, 'both'),
    ('world-stop SGI counted on CPU 1', '^ddb: intr count cpu=1 intid=1 count=[1-9][0-9]*$', 1, 1, 'both'),
    ('CPU 1 timer PPI counted', '^ddb: intr count cpu=1 intid=30 count=[1-9][0-9]*$', 1, 1, 'both'),
    ('scheduler fields', '^ddb: sched enabled=[01] pending=[01] current=[0-9]+ ready=[0-9]+ running=[0-9]+ blocked=[0-9]+ exited=[0-9]+( constructing=[1-9][0-9]*)? truncated=[01]$', 1, None, 'both'),
    ('current process fields', '^ddb: current pid=[0-9]+ parent=[0-9]+ state=[0-9]+ wait=[0-9]+$', 1, None, 'both'),
    ('CPU 0 activity', '^ddb: activity cpu=0 [a-z-]+ current=[0-9]+ stack=[0-9]+$', 1, None, 'both'),
    ('CPU 1 activity', '^ddb: activity cpu=1 [a-z-]+ current=[0-9]+ stack=[0-9]+$', 1, None, 'both'),
    ('VM fields', '^ddb: vm pid=[0-9]+ root=[0-9]+ live=[01] asid=[0-9]+ l1=0x[0-9a-f]+$', 1, None, 'both'),
    ('fd table fields', '^ddb: fds pid=[0-9]+ slots=[0-9]+$', 1, None, 'both'),
    ('process count', '^ddb: ps count=[1-9][0-9]* truncated=[01]$', 1, None, 'both'),
    ('PID 1 signal fields in ps', '^ddb: ps pid=1 ppid=0 state=[0-9]+ wait=[0-9]+( waker=[a-z-]+( queued=[0-9]+( low-water=[0-9]+)?| frame-pending=(yes|no|unknown) connection-pending=(yes|no|unknown))?)? root=0 sp=0x[0-9a-f]+ pending={sigset} masked={sigset} owner=(none|[0-9]+) mask=0x[0-9a-f]+ core0=[01]$', 1, None, 'both'),
    ('stack count', '^ddb: stacks cpus=2 processes=', 1, None, 'both'),
    ('PID 1 signal fields in proc', '^ddb: proc pid=1 ppid=0 state=[0-9]+ wait=[0-9]+( waker=[a-z-]+( queued=[0-9]+( low-water=[0-9]+)?| frame-pending=(yes|no|unknown) connection-pending=(yes|no|unknown))?)? root=0 sp=0x[0-9a-f]+ pending={sigset} masked={sigset} owner=(none|[0-9]+) mask=0x[0-9a-f]+ core0=[01]$', 1, None, 'both'),
    ('backtrace sources', '^ddb: bt source=(cpu cpu=[0-9]+|saved) pid=[0-9]+ stack=0x[0-9a-f]+\\.\\.0x[0-9a-f]+$', 2, None, 'both'),
    ('backtrace roots', '^ddb: bt frame=0 pc=0x[0-9a-f]+ boundary=(exception|user|assembly|assembly-bridge)$', 2, None, 'both'),
    ('backtrace termination', '^ddb: bt (complete frames=[1-9][0-9]*|stop=(assembly-boundary|depth-limit|invalid-return-pc|nonmonotonic-frame|out-of-range) fp=0x[0-9a-f]+)$', 1, None, 'both'),
    ('backtrace usage', '^ddb: usage: bt \\[PID\\|cpu N\\]$', 1, None, 'both'),
    ('stopped peer backtrace', '^ddb: bt source=stopped cpu=1 pid=[0-9]+ stack=0x[0-9a-f]+\\.\\.0x[0-9a-f]+$', 1, None, 'both'),
    ('invalid CPU refusal', '^ddb: bt cpu=9 not stopped here$', 1, None, 'both'),
    ('unheld stopped root refusal', '^ddb: bt test stopped-root unheld verdict=not-stopped$', 1, None, 'both'),
    ('publishing stopped root refusal', '^ddb: bt test stopped-root publishing verdict=not-stopped$', 1, None, 'both'),
    ('moved stopped root refusal', '^ddb: bt test stopped-root moved verdict=changed$', 1, None, 'both'),
    ('retired stopped root refusal', '^ddb: bt test stopped-root retired verdict=not-stopped$', 1, None, 'both'),
    ('settled stopped root acceptance', '^ddb: bt test stopped-root settled verdict=usable$', 1, None, 'both'),
    ('missing PID refusal', '^ddb: bt pid not captured$', 1, None, 'both'),
    ('unsupported PC refusal', '^ddb: bt stop=unsupported-pc fp=0x', 1, None, 'both'),
    ('misaligned PC refusal', '^ddb: bt stop=misaligned-pc fp=0x', 1, None, 'both'),
    ('misaligned frame refusal', '^ddb: bt stop=misaligned-frame fp=0x0000000000000003$', 1, None, 'both'),
    ('out of range frame refusal', '^ddb: bt stop=out-of-range fp=0x', 1, None, 'both'),
    ('depth limited frame refusal', '^ddb: bt stop=depth-limit fp=0x', 1, None, 'both'),
    ('invalid saved contexts refusal', '^ddb: bt test invalid saved contexts rejected$', 1, None, 'both'),
    ('lifecycle trace count', '^ddb: trace count=', 1, None, 'both'),
    ('diagnostic event count', '^ddb: events cpu=0 count=', 1, None, 'both'),
    ('unimplemented syscall count', '^ddb: unimpl count=0$', 1, None, 'both'),
    ('kernel read address', '^ddb: xk address=0x0*{address} count=2$', 1, None, 'both'),
    ('kernel read bytes', '^ddb: xk byte address=0x.* value=0x', 2, None, 'both'),
    ('kernel and physical read usage count', '^ddb: usage: xk\\|xp HEX_ADDRESS \\[COUNT_1_TO_64\\]$', 2, 2, 'both'),
    ('kernel read denied address', '^ddb: xk denied \\(not ordinary kernel RAM\\) address=0x0000001000000000 count=1$', 1, None, 'both'),
    ('guarded kernel read fault', '^ddb: xk fault address=0x0000000800000000$', 1, None, 'both'),
    ('guarded fault matching authority', '^ddb: xk guarded-fault armed-match ours=yes$', 1, None, 'both'),
    ('guarded fault wrong address refusal', '^ddb: xk guarded-fault armed-other-address ours=no$', 1, None, 'both'),
    ('guarded fault wrong class refusal', '^ddb: xk guarded-fault armed-other-class ours=no$', 1, None, 'both'),
    ('guarded fault unarmed refusal', '^ddb: xk guarded-fault unarmed ours=no$', 1, None, 'both'),
    ('physical read address', '^ddb: xp physical=0x0*{address} count=2$', 1, None, 'both'),
    ('physical read bytes', '^ddb: xp byte physical=0x.* value=0x', 2, None, 'both'),
    ('physical read denied address', '^ddb: xp denied \\(not ordinary physical RAM\\) address=0x0000001000000000 count=1$', 1, None, 'both'),
    ('user read address', '^ddb: xu pid=1 root=0 address=0x0000000080000000 count=2$', 1, None, 'both'),
    ('user read bytes', '^ddb: xu byte address=0x000000008000000[01] physical=0x[0-9a-f]* value=0x[0-9a-f]*$', 2, None, 'both'),
    ('user page boundary read', '^ddb: xu pid=1 root=0 address=0x0000000080000fff count=2$', 1, None, 'both'),
    ('user page boundary first byte', '^ddb: xu byte address=0x0000000080000fff physical=0x', 1, None, 'both'),
    ('user page boundary second byte', '^ddb: xu byte address=0x0000000080001000 physical=0x', 1, None, 'both'),
    ('user read usage count', '^ddb: usage: xu PID HEX_ADDRESS \\[COUNT_1_TO_64\\]$', 2, 2, 'both'),
    ('user missing PID refusal', '^ddb: xu pid not captured$', 1, None, 'both'),
    ('user unmapped address refusal', '^ddb: xu unmapped address=0x0000000070000000$', 1, None, 'both'),
    ('command inventory', '^commands: oops regs intr sched current vm fds ps stacks wait proc PID bt \\[PID\\|cpu N\\] trace events unimpl xk ADDRESS \\[COUNT\\] xp PHYSICAL \\[COUNT\\] xu PID ADDRESS \\[COUNT\\] help continue$', 1, None, 'both'),
    ('live wait current fields', '^ddb: wait current=[0-9]+ state=[a-z-]+ reason=[a-z-]+( queued=[0-9]+( low-water=[0-9]+)?| frame-pending=(yes|no|unknown) connection-pending=(yes|no|unknown))? awaited=[01]$', 1, None, 'both'),
    ('live wait graph summary', '^ddb: wait edges=[0-9]+ blocked=[0-9]+ unknown=[0-9]+ truncated=[01]$', 1, None, 'both'),
    ('synthetic current net wait', '^ddb: wait current=3 state=running reason=net-rx frame-pending=no connection-pending=unknown awaited=1$', 1, None, 'both'),
    ('synthetic grandparent wait', '^ddb: wait pid=1 state=blocked waits-for child pid=2 state=blocked$', 1, None, 'both'),
    ('synthetic parent wait', '^ddb: wait pid=2 state=blocked waits-for child pid=3 state=running$', 1, None, 'both'),
    ('synthetic child net wait', '^ddb: wait pid=3 state=running waits-for event=net-rx frame-pending=no connection-pending=unknown$', 1, None, 'both'),
    ('synthetic missing child', '^ddb: wait pid=9 state=blocked waits-for child unknown$', 1, None, 'both'),
    ('synthetic UART RX wait', '^ddb: wait pid=10 state=blocked waits-for event=uart-rx queued=1$', 1, None, 'both'),
    ('synthetic deadline wait', '^ddb: wait pid=11 state=blocked waits-for event=deadline$', 1, None, 'both'),
    ('synthetic signal wait', '^ddb: wait pid=12 state=blocked waits-for event=signal$', 1, None, 'both'),
    ('synthetic unknown wait', '^ddb: wait pid=13 state=blocked waits-for unknown$', 1, None, 'both'),
    ('synthetic UART TX wait', '^ddb: wait pid=14 state=blocked waits-for event=uart-tx queued=320 low-water=256$', 1, None, 'both'),
    ('synthetic network wait', '^ddb: wait pid=15 state=blocked waits-for event=net-rx frame-pending=no connection-pending=unknown$', 1, None, 'both'),
    ('synthetic graph summary', '^ddb: wait edges=8 blocked=9 unknown=2 truncated=1$', 1, None, 'both'),
    ('synthetic process wait rendering', '^ddb: waittest ps pid=10 ppid=0 state=3 wait=1 waker=uart-rx queued=1 root=0 sp=0x0000000000000000 pending=none masked=none owner=none mask=0x0000000000000000 core0=0$', 1, None, 'both'),
    ('continue marker', '^ddb: continuing$', 1, None, 'both'),
    ('console queued after continue', '^ddb: console tx=queued$', 1, None, 'both'),
    ('console guard release', '^ddb: console lock probe phase=2 release=[123] entry-held=(yes|no)$', 1, None, 'uart'),
    ('shell bootstrap', '^init: ash bootstrap$', 1, None, 'both'),
)


_REGEX_META = set(".^$*+?{}[]\\|()")


def _count_lines(expression, text, lines):
    """re.findall(expression, text, re.MULTILINE), counted over only the
    lines that start with the expression's literal prefix. Exact for an
    expression anchored at ^ with nothing that can match a newline (no
    REQUIREMENTS entry has one): its every match starts at a line start with
    that prefix and ends on the same line. Unanchored ones scan the text.
    Scanning every line for each of ~80 requirements made this the slowest
    fast-gate member under load (#703)."""
    if not expression.startswith("^"):
        return len(re.findall(expression, text, re.MULTILINE))
    prefix = []
    for char in expression[1:]:
        if char in _REGEX_META:
            break
        prefix.append(char)
    prefix = "".join(prefix)
    candidates = "\n".join(line for line in lines if line.startswith(prefix))
    return len(re.findall(expression, candidates, re.MULTILINE))


def capture_problems(text, metadata, hold_text=""):
    """Return all failed independent requirements; never contact a guest."""
    text = text.replace("\r", "")
    lines = text.split("\n")
    source = metadata["break_source"]
    replacements = {
        "entry": "irq" if source == "uart" else "brk",
        "source": "33" if source == "uart" else "21579",
        "address": f'{metadata["kernel_address"]:x}',
        "sigset": SIGNALS,
    }
    problems = []
    for name, expression, minimum, maximum, applies in REQUIREMENTS:
        if applies != "both" and applies != source:
            continue
        for key, value in replacements.items():
            expression = expression.replace("{" + key + "}", value)
        count = _count_lines(expression, text, lines)
        if count < minimum or maximum is not None and count > maximum:
            bound = str(minimum) if maximum == minimum else f"at least {minimum}"
            problems.append(f"{name}: expected {bound} matching line(s), found {count}")

    def has(expression):
        return re.search(expression, text, re.MULTILINE) is not None

    if has(r"^ddb: intr count cpu=0 intid=2 "):
        problems.append("fixture SGI on CPU 0: counted on a CPU it was not raised on")

    if source == "uart":
        if not re.search(r"^PASS console BREAK injection: peer guard and phase are held$",
                         hold_text.replace("\r", ""), re.MULTILINE):
            problems.append("console BREAK injection: no observed peer guard")
        if not has(r"^ddb: ps pid=1 ppid=0 .* masked=(sigint|sigquit|sigterm|sigchld|sigtstp)([,+]|$)"):
            problems.append("PID 1 signal mask: no accepted signal named in live state")
        # Only the first wait graph describes the real terminal reader; the
        # later waittest graph is synthetic and cannot stand in for it.
        start = text.find("ddb: wait current=")
        end = text.find("ddb: wait edges=", start)
        live = text[start:end] if 0 <= start < end else ""
        readers = re.findall(r"^ddb: wait pid=([0-9]+) state=blocked waits-for event=uart-rx queued=[0-9]+$", live, re.MULTILINE)
        processes = {pid: (ppid, state, wait) for pid, ppid, state, wait in re.findall(
            r"^ddb: ps pid=([0-9]+) ppid=([0-9]+) state=([0-9]+) wait=([0-9]+) ", text, re.MULTILINE)}
        reader = processes.get(readers[0]) if len(readers) == 1 else None
        if (reader is None or reader[1:] != ("3", "1") or
                processes.get(reader[0], ("", "", ""))[2] != "2"):
            problems.append("peer terminal reader: not blocked on UART RX under its waiting parent")
        continuing = text.find("ddb: continuing\n")
        if continuing < 0 or text.find("workload: peer tty read its 17-byte line", continuing) < 0:
            problems.append("peer terminal delivery: line was not delivered after continue")
        matched = len(re.findall(r"^ddb: stack cpu=[01] pid=[0-9]+ stack=0x[0-9a-f]+\.\.0x[0-9a-f]+ owner=(none|[01]) record=match$", text, re.MULTILINE))
        two = has(r"^ddb: stacks roots=2 matched=2 missing=0 duplicate-process=0 owner-mismatch=0 range-mismatch=0 duplicate-pid=0 duplicate-stack=0$")
        one = has(r"^ddb: stack cpu=1 status=idle$") and has(r"^ddb: stacks roots=1 matched=1 missing=0 duplicate-process=0 owner-mismatch=0 range-mismatch=0 duplicate-pid=0 duplicate-stack=0$")
        if not (matched == 2 and two or matched == 1 and one):
            problems.append("migration stack attribution: roots were not unique")
        for name, expression in (
                ("late UART backtrace", r"^ddb: bt stop=user-boundary fp=0x"),
                ("late UART event overflow", r"^ddb: events cpu=0 count=[1-9][0-9]* damaged=0 overwritten=[1-9][0-9]*$"),
                ("late UART event record", r"^ddb: event seq=[1-9][0-9]* cpu=0 id=0x0000000000000101 a=0x")):
            if not has(expression):
                problems.append(name + ": missing evidence")
        migrated = text.find("workload: busy pair migrated across both cpus with stack handoff intact\n")
        stacks = text.find("ddb: stacks cpus=2 processes=")
        if not 0 <= migrated < stacks:
            problems.append("snapshot ordering: snapshot did not follow live migration")
    else:
        if not (has(r"^ddb: stack cpu=1 status=idle$") and has(r"^ddb: stacks roots=1 matched=1 missing=0 duplicate-process=0 owner-mismatch=0 range-mismatch=0 duplicate-pid=0 duplicate-stack=0$")):
            problems.append("boot idle root: CPU 1 was not idle with one matched root")
        problems.extend("software BRK walk: " + problem for problem in backtrace_problems(
            text, metadata["generated_start"], metadata["generated_end"]))
    return problems
