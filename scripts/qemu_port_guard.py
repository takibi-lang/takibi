#!/usr/bin/env python3
"""Refuse to start a QEMU lane whose ports somebody else already owns.

GitHub issue #407. A lane whose host-side peer cannot bind its UDP port
fails with `OSError: [Errno 98] Address already in use`, and the runner
then reports `error: no UART output captured -- kernel did not boot` --
naming the kernel for something the kernel was never asked about. This
runs first and says what is actually wrong.

It also reaps an ORPHAN of the same lane, and only that. The runner takes
an flock on its artifact directory before calling this, so a concurrent
run of this lane is already refused one step earlier; reaching here with
one of our ports held means no runner owns the lane and a QEMU with our
exact ports is nonetheless alive, which is a leak from an interrupted
run. Anything else -- another lane, another tool, a process whose command
line does not name this port -- is reported and never killed: killing a
process this script did not start is worse than refusing to run.

  usage: qemu_port_guard.py LABEL SPEC...      SPEC = udp:18671 | tcp:18673
"""

import os
import re
import signal
import socket
import subprocess
import sys
import time

REAP_TERM_WAIT_SECS = 2.0
REAP_POLL_SECS = 0.05


def parse_spec(spec):
    proto, _, port = spec.partition(":")
    if proto not in ("udp", "tcp") or not port.isdigit():
        raise SystemExit("qemu_port_guard: bad spec %r (want udp:N or tcp:N)" % spec)
    return proto, int(port)


def port_is_free(proto, port):
    """Bind it the way its real user will, and give it straight back.

    Deliberately without SO_REUSEADDR: the question is whether the real
    bind below will succeed, and the peer and QEMU do not set it either.
    A pre-flight check cannot hold the port -- this is diagnosis, not
    mutual exclusion -- so a race is possible and harmless: the loser
    still fails, just with its own message.
    """
    family = socket.SOCK_DGRAM if proto == "udp" else socket.SOCK_STREAM
    with socket.socket(socket.AF_INET, family) as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def holders(proto, port):
    """(pid, cmdline) for every process holding this port, best effort.

    `ss` needs no privilege for our own processes, which is the case that
    matters: a leaked QEMU is one of ours.
    """
    flag = "-lunp" if proto == "udp" else "-ltnp"
    try:
        out = subprocess.run(["ss", "-H", flag], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    found = []
    for line in out.splitlines():
        if ":%d " % port not in line + " ":
            continue
        for pid in re.findall(r"pid=(\d+)", line):
            found.append((int(pid), cmdline_of(int(pid))))
    return found


def cmdline_of(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as handle:
            return handle.read().replace(b"\0", b" ").decode(errors="replace").strip()
    except OSError:
        return ""


def is_our_orphan(cmdline, port):
    """A QEMU started for THIS lane's port, and nothing else.

    Both forms this tree uses are named explicitly rather than matched
    loosely: the netdev spec carries `local.port=`/`remote.port=`, and the
    serial and gdb ports appear as `:PORT`. A match on the bare number
    anywhere in a command line would be a licence to kill the wrong thing.
    """
    if "qemu-system-" not in cmdline:
        return False
    return any(token in cmdline for token in (
        "local.port=%d" % port,
        "remote.port=%d" % port,
        ":%d," % port,
        ":%d " % port,
    )) or cmdline.endswith(":%d" % port)


def reap(pid):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        deadline = time.monotonic() + REAP_TERM_WAIT_SECS
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(REAP_POLL_SECS)
    return False


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    label = sys.argv[1]
    failed = False
    for spec in sys.argv[2:]:
        proto, port = parse_spec(spec)
        if port_is_free(proto, port):
            continue
        held = holders(proto, port)
        orphans = [(pid, cmd) for pid, cmd in held if is_our_orphan(cmd, port)]
        if orphans and len(orphans) == len(held):
            for pid, cmd in orphans:
                print("[%s] %s/%d was held by an orphaned runner (pid %d); "
                      "reaping it" % (label, proto, port, pid), file=sys.stderr)
                if not reap(pid):
                    print("[%s] could not reap pid %d" % (label, pid),
                          file=sys.stderr)
            if port_is_free(proto, port):
                continue
        failed = True
        print("FAIL %s: %s port %d is already in use, so this lane cannot "
              "start." % (label, proto, port), file=sys.stderr)
        if held:
            for pid, cmd in held:
                print("       held by pid %d: %s" % (pid, cmd or "(unknown)"),
                      file=sys.stderr)
            print("       Not reaped: only a qemu-system process whose own "
                  "command line names this port is treated as this lane's "
                  "orphan.", file=sys.stderr)
        else:
            print("       The holder could not be identified (ss unavailable, "
                  "or the socket belongs to another user).", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
