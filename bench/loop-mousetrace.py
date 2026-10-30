#!/usr/bin/env python3
# Loop-surface probe (perf audit round A). Not part of the build or the test suite: run it by hand,
# as documented in the issue it belongs to. Nothing here captures the desktop -- krd runs --mock.
import os, pty, sys, time, select, struct, fcntl, termios

seconds = float(sys.argv[1]); rate = float(sys.argv[2]); argv = sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
data = bytearray()
def drain(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.005)
        if r:
            try: data.extend(os.read(fd, 65536))
            except OSError: return
drain(2.0)
t0 = time.time(); n = 0
while time.time() - t0 < seconds:
    # SGR 1016 pixel motion report (button 35 = no button, motion)
    os.write(fd, f"\x1b[<35;{100 + n % 700};{100 + n % 400}M".encode())
    n += 1
    drain(1.0 / rate)
os.write(fd, b"\x1c"); time.sleep(0.1); os.write(fd, b"q")
drain(1.0)
try: os.close(fd)
except OSError: pass
try: os.waitpid(pid, 0)
except Exception: pass
print(f"sent {n} motion reports in {seconds:.0f}s; product wrote {len(data)} bytes to the pty")
