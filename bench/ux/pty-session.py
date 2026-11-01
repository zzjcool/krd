#!/usr/bin/env python3
"""Run a command on a pty of a given size, optionally type into it, and dump the bytes.

No terminal emulator is involved: this is the instrument for the *text* half of the chrome
(`Sources/krd/Chrome.swift`), which `--pane`/`--cell` make deterministic without a real
terminal. Use it to answer "what does the user see" for anything the TUI layer draws:

    bench/ux/pty-session.py --cols 80 --rows 24 --secs 4 -- out.bin -- \\
        .build/release/krd --mock --dev --mirror --pane 80x24 --cell 8x16 --debug

    bench/ux/pty-session.py --cols 80 --rows 24 --secs 5 --at 2 --type '\\x1c' -- out.bin -- \\
        .build/release/krd --mock --dev --mirror --pane 80x24 --cell 8x16

`--type` takes python escape syntax, so `\\x1c` is Ctrl-\\, `\\x1b[<0;20;24M` is an SGR mouse
press, and so on. The bytes are written to the pty *as typed*, i.e. on the same input path a
keyboard uses — which is why this can prove or disprove an input bug without a human.

The pty gets a real winsize (`--cols`/`--rows`) so krd's SIGWINCH path re-measures something
sane; the *pixel* size is still 0x0, so pass `--cell` to krd or the layout falls back.

Exit status: the child's, or 124 if it outlived `--secs` and was signalled.
"""
import argparse
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--secs", type=float, default=4.0, help="wall-clock run time")
    ap.add_argument("--at", type=float, default=None, help="when to type (default: never)")
    ap.add_argument("--type", default="", help="bytes to type, python escapes")
    ap.add_argument("out", help="file to write everything the child wrote")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()

    cmd = a.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        ap.error("no command")

    typed = a.type.encode().decode("unicode_escape").encode("latin1")

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ,
                struct.pack("HHHH", a.rows, a.cols, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(master)
        os.close(slave)
        os.execv(cmd[0], cmd)

    os.close(slave)
    buf = bytearray()
    t0 = time.time()
    sent = False
    status = 124
    while time.time() - t0 < a.secs:
        if not sent and a.at is not None and time.time() - t0 >= a.at:
            os.write(master, typed)
            sent = True
        r, _, _ = select.select([master], [], [], 0.1)
        if master not in r:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    if status == 124:
        os.kill(pid, signal.SIGTERM)
    try:
        _, wait = os.waitpid(pid, 0)
        status = os.waitstatus_to_exitcode(wait)
    except ChildProcessError:
        pass
    with open(a.out, "wb") as f:
        f.write(buf)
    return status


if __name__ == "__main__":
    sys.exit(main())
