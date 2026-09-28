"""Drive the EL0 termios probe and verify the actual UART byte stream."""


class TerminalScenario:
    phases = (
        (b"canonical input", b"abc\x7fx\n"),
        (b"editing input", b"lost\x15one two\x17X\x12\t\x7f\x16\x03\n"),
        (b"empty EOF input", b"\x04"),
        (b"tail EOF input", b"eof-tail\x04"),
        (b"raw input", b"raw-proof"),
        (b"newline echo input", b"hidden\n"),
        (b"output flow input", b"\x13FLOW\n\x11"),
        (b"input flow input", b"F" * 3100),
        (b"masked signals input", b"\x03\x1c\x1a\n"),
        (b"orphan SUSP input", b"\x1a\n"),
        (b"fatal INT arm", b"\n"),
        (b"fatal INT input", b"\x03"),
        (b"fatal QUIT arm", b"\n"),
        (b"fatal QUIT input", b"\x1c"),
    )

    def __init__(self):
        self.started = False
        self.done = False
        self.round = 0
        self.phase = 0
        self.cursor = 0
        self.start = None
        self.flow_newline = False
        self.evidence = []

    def launch(self, connection, output):
        self.started = True
        self.cursor = len(output)
        connection.write(b"/bin/termios\r\n")

    def step(self, connection, output):
        if not self.started or self.done:
            return
        raw = bytes(output)
        if b"termios: FAIL" in raw[self.cursor:]:
            raise RuntimeError("EL0 termios probe failed")
        if self.start is not None and self.phase == 7 and not self.flow_newline:
            if b"\x13" in raw[self.start:]:
                connection.write(b"\n")
                self.flow_newline = True
        name, payload = self.phases[self.phase]
        marker = b"termios: " + name + b"\r\n"
        found = raw.find(marker, self.cursor)
        if self.start is None:
            if found >= 0:
                self.start = found + len(marker)
                connection.write(payload)
            return
        next_phase = self.phase + 1
        if next_phase == len(self.phases):
            if self.round == 0:
                next_marker = b"termios: canonical input\r\n"
            else:
                next_marker = b"termios: every check PASS\r\n"
        else:
            next_marker = b"termios: " + self.phases[next_phase][0] + b"\r\n"
        end = raw.find(next_marker, self.start)
        if end < 0:
            return
        segment = raw[self.start:end]
        self.check_segment(segment)
        self.evidence.append((self.round, self.phase))
        self.cursor = end
        self.start = None
        self.flow_newline = False
        self.phase = next_phase
        if self.phase == len(self.phases):
            self.phase = 0
            self.round += 1
            if self.round == 2:
                self.done = True

    def check_segment(self, segment):
        if self.phase == 0 and b"abc\b \bx\r\n" not in segment:
            raise RuntimeError("canonical ECHO/ECHOE bytes did not reach UART")
        if self.phase == 1:
            if b"lost" + b"\b \b" * 4 not in segment:
                raise RuntimeError("ECHOKE did not erase the killed line")
            if b"one two" + b"\b \b" * 3 + b"X" not in segment:
                raise RuntimeError("IEXTEN word erasure did not reach UART")
            if b"^R\r\none X" not in segment or b"^\b^C\r\n" not in segment:
                raise RuntimeError("reprint or quoted control echo did not reach UART")
        if self.phase == 4 and b"raw-proof" in segment:
            raise RuntimeError("ECHO off still echoed the raw input")
        if self.phase == 5:
            if b"hidden" in segment or not segment.startswith(b"\r\n"):
                raise RuntimeError("ECHONL did not echo only the newline")
        if self.phase == 6 and b"FLOW\r\n" not in segment:
            raise RuntimeError("IXON did not resume queued terminal echo")
        if self.phase == 7 and (b"\x13" not in segment or b"\x11" not in segment):
            raise RuntimeError("IXOFF did not send both XOFF and XON")

    def validate(self):
        if not self.done or len(self.evidence) != 28:
            raise RuntimeError(
                f"termios scenario incomplete: CPU round {self.round}, phase {self.phase}")
