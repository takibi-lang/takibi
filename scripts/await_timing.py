"""Arrival observations for the maintained oops and QEMU DDB drivers.

Each recorder describes one existing common deadline. Separate driver and
postmortem phases do not reset or reinterpret each other's timeout.
"""

import json


class AwaitTiming:
    """Observe the driver's existing common deadline without changing it."""

    def __init__(self, path, started, timeout, awaited, commands, *,
                 label="kernel/oops", origin="driver start", connection=True):
        self.started = started
        self.timeout = timeout
        self.label = label
        self.origin = origin
        self.pending = {"UART connection": None} if connection else {}
        self.pending.update({f"await-line {i + 1}": text.decode("ascii")
                             for i, text in enumerate(awaited)})
        self.pending["console prompt 1"] = "ddb> "
        self.pending.update({f"console prompt {i + 2} (after {command.decode('ascii').strip()})": "ddb> "
                             for i, command in enumerate(commands)})
        self.prompt_names = [name for name in self.pending if name.startswith("console prompt")]
        self.path = path
        if path:
            try:
                with open(path, "w", encoding="ascii"):
                    pass
            except OSError as error:
                print(f"RECORDED {self.label} await timing unavailable: {error}", flush=True)
                self.path = None

    def record(self, name, arrived, now):
        if name not in self.pending:
            return
        marker = self.pending.pop(name)
        elapsed = now - self.started
        fraction = elapsed / self.timeout if arrived else None
        row = {"await": name, "marker": marker, "budget_origin": self.origin,
               "elapsed_seconds": elapsed if arrived else None,
               "observed_seconds": elapsed, "timeout_seconds": self.timeout,
               "fraction": fraction, "status": "arrived" if arrived else "not-arrived"}
        if self.path:
            try:
                with open(self.path, "a", encoding="ascii") as handle:
                    handle.write(json.dumps(row) + "\n")
            except OSError as error:
                print(f"RECORDED {self.label} await timing unavailable: {error}", flush=True)
                self.path = None
        if arrived and fraction > 0.5:
            label = f"{name} ({marker!r})" if marker and marker != "ddb> " else name
            print(f"RECORDED {self.label} await margin: {label} arrived at "
                  f"{elapsed:.3f}s/{self.timeout:.3f}s ({fraction:.1%}); "
                  "more than half the common timeout used", flush=True)

    def finish(self, now):
        for name in list(self.pending):
            self.record(name, False, now)
