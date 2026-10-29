#!/usr/bin/env python3
"""Clickable kitty-graphics image in a terminal pane (pure stdlib).

Places a colour-wheel image at cell (1,1) with C=1 (cursor does not move),
then enables SGR mouse reporting and maps every click back to image pixels
by hit-testing the known placement rect.  No terminal-specific image-click
API involved: any terminal that can (a) draw the graphics protocol and
(b) report mouse events will work.

Keys:  click / h j k l  move probe   q / Ctrl-C / Esc  quit
"""
import os, sys, termios, tty, select, math, zlib, struct, base64

W, H = 360, 200          # image pixels
COLS, ROWS = 45, 12      # placement size in terminal cells

# ---------------------------------------------------------------- image data
def hsv(h, s, v):
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    return [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]


def sample(x, y):
    """Colour at image pixel (x, y) -- same maths as the PNG builder."""
    dx, dy = x - W / 2, y - H * 0.5
    r = math.hypot(dx, dy) / (H * 0.5)
    hue = (math.atan2(dy, dx) / (2 * math.pi)) % 1.0
    col = hsv(hue, min(1.0, r * 1.1), 1.0 - 0.75 * min(1.0, r * r))
    if (x // 30 + y // 30) % 2 == 0:
        col = [c * 0.82 for c in col]
    if abs(r - 0.55) < 0.02 or abs(r - 0.78) < 0.02:
        col = [1.0, 1.0, 1.0]
    return tuple(int(max(0.0, min(1.0, c)) * 255) for c in col), hue, r


def png():
    rows = bytearray()
    for y in range(H):
        rows.append(0)
        for x in range(W):
            rows.extend(sample(x, y)[0])

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b''))


def emit_image():
    b64 = base64.b64encode(png()).decode()
    out = sys.stdout
    step = 4096
    for i in range(0, len(b64), step):
        part = b64[i:i + step]
        more = 0 if i + step >= len(b64) else 1
        out.write(f"\033_Gf=100,a=T,q=2,C=1,c={COLS},r={ROWS},m={more};{part}\033\\")

# ------------------------------------------------------------------ hit test
def probe(cx, cy):
    """cell coords (1-based, relative to screen) -> report string"""
    fx = (cx - 0.5) / COLS
    fy = (cy - 0.5) / ROWS
    px = int(max(0, min(W - 1, fx * W)))
    py = int(max(0, min(H - 1, fy * H)))
    (r, g, b), hue, radius = sample(px, py)
    return (f"\033[K  cell ({cx:2d},{cy:2d}) -> image px ({px:3d},{py:3d})"
            f"  rgb #{r:02x}{g:02x}{b:02x}  hue {hue*360:5.1f}deg  r={radius:.2f}")

# ---------------------------------------------------------------------- main
MOUSE_ON = "\033[?1000h\033[?1006h"
MOUSE_OFF = "\033[?1000l\033[?1006l"
STATUS_ROW = ROWS + 3
cur = (COLS // 2, ROWS // 2)


def draw(msg="click anywhere on the image / h j k l to move / q to quit"):
    w = sys.stdout.write
    w(f"\033[{STATUS_ROW};1H\033[K  {msg}")
    w(f"\033[{STATUS_ROW + 1};1H\033[K{probe(*cur)}")
    w(f"\033[{STATUS_ROW + 2};1H\033[K  q = quit, Ctrl-C = quit")
    w(f"\033[{STATUS_ROW + 1};1H")
    sys.stdout.flush()


def main():
    global cur
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    w = sys.stdout.write
    try:
        w("\033[2J\033[H\033[?25l")
        emit_image()
        w("\033[?25l")
        draw()
        w(MOUSE_ON)
        sys.stdout.flush()
        buf = b""
        while True:
            r, _, _ = select.select([fd], [], [], 0.5)
            if not r:
                continue
            buf += os.read(fd, 1024)
            while buf:
                m = buf.find(b"\033[<")
                if m >= 0:
                    e = buf.find(b"M", m), buf.find(b"m", m)
                    e = min([x for x in e if x >= 0], default=-1)
                    if e < 0:
                        break
                    try:
                        b, x, y = (int(v) for v in buf[m + 3:e].split(b";"))
                    except ValueError:
                        buf = buf[e + 1:]
                        continue
                    buf = buf[e + 1:]
                    if b & 3 == 0 and not b & 32:          # left press
                        cx, cy = min(x, COLS), min(y, ROWS)
                        cur = (cx, cy)
                        draw("clicked")
                    continue
                # plain keys
                ch = buf[:1]
                buf = buf[1:]
                if ch in (b"q", b"\x03", b"\x1b"):
                    return
                if ch == b"h":
                    cur = (max(1, cur[0] - 1), cur[1])
                elif ch == b"l":
                    cur = (min(COLS, cur[0] + 1), cur[1])
                elif ch == b"k":
                    cur = (cur[0], max(1, cur[1] - 1))
                elif ch == b"j":
                    cur = (cur[0], min(ROWS, cur[1] + 1))
                else:
                    continue
                draw("keys")
    finally:
        w(MOUSE_OFF + "\033[?25h")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
