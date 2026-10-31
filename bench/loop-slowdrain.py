#!/usr/bin/env python3
"""Run krd behind a pty (100x40) that drains at `speed` bytes/s, for `seconds`.

The point (issue #93): a drain this slow makes a single `write(2)` block for seconds -- the
picture freezes and the quality ladder has to see it. Counting late *frames*, it never did:
the hang deleted the frames that would have been its samples.

    python3 bench/loop-slowdrain.py 5000 34 .build/release/krd --mock --pane 100x40 \
        --cell 10x20 --fps 20 --quality auto --debug --log /tmp/gov.log --stats-json /tmp/gov.json
    grep -c 'pipe is behind' /tmp/gov.log     # 4 on this branch, 0 on main before #93

The process is killed at the end of the window (`SIGKILL` to its group), so a hung krd is
never left behind.
"""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

speed = int(sys.argv[1])
seconds = float(sys.argv[2])
cmd = sys.argv[3:]
rows, cols = 40, 100

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                        preexec_fn=os.setsid, close_fds=True)
os.close(slave)
os.set_blocking(master, False)

tick = 0.05                       # 20 Hz of *draining*, well under the frame rate
per_tick = max(1, int(speed * tick))
deadline = time.time() + seconds
drained = 0
try:
    while time.time() < deadline and proc.poll() is None:
        started = time.time()
        budget = per_tick
        while budget > 0:
            try:
                chunk = os.read(master, min(budget, 4096))
            except (BlockingIOError, OSError):
                break
            if not chunk:
                break
            drained += len(chunk)
            budget -= len(chunk)
        left = tick - (time.time() - started)
        if left > 0:
            time.sleep(left)
finally:
    # Cap: never leave krd running.
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except OSError:
        pass
    proc.wait(timeout=10)
print(f"drained {drained} B in {seconds:.0f} s ({drained/seconds/1024:.1f} KB/s)")
