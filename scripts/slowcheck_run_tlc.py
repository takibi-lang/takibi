#!/usr/bin/env python3
"""Check concurrent TLC temporary-file isolation and failed-JVM cleanup."""
from pathlib import Path
import os
import subprocess
import tempfile
import time

from pass_line import CaseCount, report_pass


ROOT = Path(__file__).resolve().parent.parent


def main():
    cases = CaseCount()
    with tempfile.TemporaryDirectory(prefix="takibi-tlc-control-") as name:
        work = Path(name)
        java = work / "java"
        # Mimic the resolver's fixed module basename. Both JVMs keep their
        # files alive until the parent has observed the two ready markers.
        java.write_text('''#!/usr/bin/env python3
from pathlib import Path
import os, sys, time
args = sys.argv[1:]
if not args or not args[0].startswith('-Djava.io.tmpdir='):
    sys.exit('missing private TLC temporary directory')
tmp = Path(args.pop(0).split('=', 1)[1])
tag, status = args
module = tmp / 'Integers.tla'
module.write_text(tag)
control = Path(os.environ['TLC_CONTROL'])
(control / (tag + '.ready')).write_text(str(tmp))
deadline = time.monotonic() + 5
while not (control / 'release').exists():
    if time.monotonic() > deadline:
        sys.exit('control rendezvous timed out')
    time.sleep(0.01)
if module.read_text() != tag:
    sys.exit('TLC standard module was overwritten')
sys.exit(int(status))
''')
        java.chmod(0o755)
        env = dict(os.environ, PATH=str(work) + os.pathsep + os.environ["PATH"],
                   TMPDIR=str(work), TLC_CONTROL=str(work))
        processes = []
        try:
            for tag, status in [("success", 0), ("failure", 23)]:
                cases.note()
                processes.append(subprocess.Popen(
                    ["bash", str(ROOT / "scripts/run_tlc.sh"), tag, str(status)],
                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True))
            deadline = time.monotonic() + 5
            markers = [work / (tag + ".ready") for tag in ["success", "failure"]]
            while not all(p.exists() for p in markers):
                if time.monotonic() > deadline:
                    raise AssertionError("TLC controls did not reach their rendezvous")
                time.sleep(0.01)
            directories = [Path(p.read_text()) for p in markers]
            assert directories[0] != directories[1], "TLC jobs share a directory"
            assert all(p.is_dir() for p in directories), "missing private directory"
            (work / "release").touch()
            for process, expected in zip(processes, [0, 23]):
                _, error = process.communicate(timeout=5)
                assert process.returncode == expected, (process.returncode, error)
            assert not any(p.exists() for p in directories), "temporary directory leaked"
            # A JVM invocation without the wrapper's private directory must
            # fail for the isolation diagnostic, independently of its status.
            bad = subprocess.run([str(java), "success", "0"], env=env,
                                 capture_output=True, text=True, timeout=5)
            cases.note()
            assert bad.returncode != 0, "unisolated negative control passed"
            assert "missing private TLC temporary directory" in bad.stderr, bad.stderr
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.communicate()
    report_pass("TLC runner controls",
                "parallel module files are isolated, exit statuses survive, "
                "and success/failure temporary directories are removed",
                cases=cases.ran)


if __name__ == "__main__":
    main()
