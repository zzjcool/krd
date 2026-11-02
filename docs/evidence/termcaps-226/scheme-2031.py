import os, select, sys, termios, time, tty
fd = os.open("/dev/tty", os.O_RDWR)
saved = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    def drain(ms):
        end = time.time() + ms / 1000
        out = b""
        while time.time() < end:
            if select.select([fd], [], [], max(0, end - time.time()))[0]:
                out += os.read(fd, 65536)
        return out
    os.write(fd, b"\x1b[?996n")
    print("?996n alone      :", repr(drain(300)))
    os.write(fd, b"\x1b[?2031h")
    print("?2031h report    :", repr(drain(600)))
    os.write(fd, b"\x1b[?2031l")
    drain(200)
    os.write(fd, b"\x1b[?2031$p")
    print("DECRQM 2031      :", repr(drain(300)))
finally:
    termios.tcsetattr(fd, termios.TCSAFLUSH, saved)
