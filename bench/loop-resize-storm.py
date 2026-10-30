#!/usr/bin/env python3
# Loop-surface probe (perf audit round A). Not part of the build or the test suite: run it by hand,
# as documented in the issue it belongs to. Nothing here captures the desktop -- krd runs --mock.
import os, pty, sys, time, select, struct, fcntl, termios, re, json, signal

burst = int(sys.argv[1]) if len(sys.argv) > 1 else 40
argv = sys.argv[2:]

pid, fd = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)

def setsize(cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

setsize(100, 40)
data = bytearray()
def drain(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            data.extend(chunk)
    return True

drain(3.0)                     # start, first frame, steady state
mark = len(data)
t0 = time.time()
for i in range(burst):
    setsize(100 + (i % 7), 40 - (i % 5))
    drain(1.0 / 30)
burst_secs = time.time() - t0
drain(2.5)                     # let the last repaint finish
os.write(fd, b"\x1c")          # Ctrl-\ prefix
time.sleep(0.2)
os.write(fd, b"q")             # quit
drain(1.0)
try:
    os.close(fd)
except OSError:
    pass
_, status = os.waitpid(pid, 0)

body = bytes(data)
DELE = body.count(b"\x1b_Ga=d,d=a")
CS2J = body.count(b"\x1b[2J")
IMAGES = len(re.findall(rb"\x1b_G[^\x1b]*a=t", body))
burst_bytes = len(body) - mark
print(json.dumps({
    "burst_events": burst, "burst_seconds": round(burst_secs, 2),
    "delete_all": DELE, "clear_2J": CS2J, "images_transmitted": IMAGES,
    "bytes_total": len(body), "bytes_during_and_after_burst": burst_bytes,
    "exit_status": status,
}))
