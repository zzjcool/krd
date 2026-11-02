#!/usr/bin/env python3
"""Exit latency of `Ctrl-\\` then `q`, measured three ways.

Round A (perf-loop) measured 603.5/603.6/605.0 ms for this exit and filed it as a
latency bug ("the last thing a user does in every session"). It is not: the harness
set up a pty and then stopped reading it. Once the pty's output buffer is full, the
process cannot finish its teardown write until someone drains it, and the harness's
own waitpid() is measuring that, not krd's exit path.

Three modes, same binary, same keys:

  drained   - pty for stdin+stdout, master keeps reading  (what a terminal does)
  no-drain  - pty for stdin+stdout, master stops reading  (round A's harness)
  file-out  - pty for stdin only, stdout to a regular file (never blocks)

    bench/exit-latency/exit_latency.py .build/release/krd --mock --dev

Expected (min of 3, 40x100, macOS 27): drained 2.2-6.1 ms, file-out 2.8-3.1 ms,
no-drain 603-606 ms. The no-drain number grows with nothing and shrinks to 3 ms if
the keys are sent before the buffer fills (--pre 0.3), which is what proves it is
the buffer and not the exit code path.
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

ROWS, COLS = 40, 100


def run(argv, mode, pre=2.0, keys=b"\x1cq"):
    if mode == "file-out":
        mfd, sfd = pty.openpty()
        fcntl.ioctl(sfd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        out = open(os.devnull, "wb")
        pid = os.fork()
        if pid == 0:
            os.close(mfd)
            os.dup2(sfd, 0)
            os.dup2(out.fileno(), 1)
            os.dup2(out.fileno(), 2)
            os.execv(argv[0], argv)
        os.close(sfd)
    else:
        pid, mfd = pty.fork()
        if pid == 0:
            os.execv(argv[0], argv)
        fcntl.ioctl(mfd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    # Warm-up: let the app start and paint, draining like a terminal.
    end = time.time() + pre
    while time.time() < end:
        r, _, _ = select.select([mfd], [], [], 0.005)
        if r:
            try:
                os.read(mfd, 1 << 20)
            except OSError:
                break

    t0 = time.monotonic()
    os.write(mfd, keys)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if mode == "drained":
            r, _, _ = select.select([mfd], [], [], 0.002)
            if r:
                try:
                    os.read(mfd, 1 << 20)
                except OSError:
                    pass
        p, _ = os.waitpid(pid, os.WNOHANG)
        if p:
            return (time.monotonic() - t0) * 1000.0
        time.sleep(0.001)
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    return float("inf")


def main():
    argv = sys.argv[1:]
    if not argv:
        sys.exit(__doc__)
    pre = 2.0
    if argv[0] == "--pre":
        pre = float(argv[1])
        argv = argv[2:]
    print(f"{'mode':10s} {'runs (ms)':40s} min")
    for mode in ("drained", "file-out", "no-drain"):
        runs = [run(argv, mode, pre) for _ in range(3)]
        print(f"{mode:10s} {' '.join(f'{r:7.1f}' for r in runs):40s} {min(runs):7.1f}")


if __name__ == "__main__":
    main()
