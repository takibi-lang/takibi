"""A caller-clock UART inactivity deadline under a separate host ceiling."""


class ProgressTimeout:
    def __init__(self, timeout, ceiling, started):
        self.timeout = timeout
        self.ceiling = started + ceiling
        self.last_progress = started

    @property
    def deadline(self):
        return min(self.last_progress + self.timeout, self.ceiling)

    def observe(self, now):
        self.last_progress = now

    def expired(self, now):
        return now >= self.deadline
