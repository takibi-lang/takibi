#!/usr/bin/env python3
"""Refuse early DMA capture termination under every UART byte split."""
from run_kernel_dma_qemutest import EXPECTED, transcript_finished
from pass_line import CaseCount, report_pass


def main():
    cases = CaseCount()
    messages = [b"FAIL dma: " + b"fragmented diagnostic\n",
                (EXPECTED[-1] + "\n").encode()]
    for message in messages:
        # Earlier complete lines must not lend their newline to a partial
        # final line. Byte-at-a-time UART delivery exposed this real defect.
        prefix = b"unrelated earlier line\n"
        for split in range(len(message)):
            cases.note()
            if transcript_finished(prefix + message[:split]):
                raise SystemExit("FAIL dma-transcript controls: partial diagnostic ended capture")
        cases.note()
        if not transcript_finished(prefix + message):
            raise SystemExit("FAIL dma-transcript controls: full diagnostic did not end capture")
    report_pass("dma-transcript controls", "every UART byte split retains the complete witness", cases=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
