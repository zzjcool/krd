#!/usr/bin/env python3
"""Clickable / draggable / zoomable image in a terminal pane (pure stdlib).

Techniques (all standard DEC/xterm mouse modes, no terminal-specific API):
  * image transmitted ONCE with i=42 (a=t), then placed with a=p and
    re-placed for zoom -- no retransmission of the PNG
  * placement pinned to cell (1,1) with C=1 -> hit-test rect is known
  * ?1002h  button-event tracking  -> press / drag-motion / release
  * ?1006h  SGR extended coordinates
  * wheel shows up as buttons 64 (up) / 65 (down)

Keys: click = probe, drag = select region + average colour,
      wheel/+- = zoom, q / Ctrl-C = quit
"""
import os, sys, termios, tty, select, math, zlib, struct, base64

IMG = 42
W, H = 360, 200
cols = 45
STATUS = 20


def rows_for(c):
    return max(3, round(c * H / (2.0 * W)))


# ------------------------------------------------------------------ imaging
def hsv(h, s, v):
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    return [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]


def sample(x, y):
    dx, dy = x - W / 2, y - H * 0.5
    r = math.hypot(dx, dy) / (H * 0.5)
    hue = (math.atan2(dy, dx) / (2 * math.pi)) % 1.0
    col = hsv(hue, min(1.0, r * 1.1), 1.0 - 0.75 * min(1.0, r * r))
    if (x // 30 + y // 30) % 2 == 0:
        col = [c * 0.82 for c in col]
    if abs(r - 0.55) < 0.02 or abs(r - 0.78) < 0.02:
        col = [1.0, 1.0, 1.0]
    if x < 2 or y < 2 or x >= W - 2 or y >= H - 2:
        col = [0.12, 0.12, 0.15]
    return tuple(int(max(0.0, min(1.0, c)) * 255) for c in col), hue, r


def png():
    buf = bytearray()
    for y in range(H):
        buf.append(0)
        for x in range(W):
            buf.extend(sample(x, y)[0])

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(bytes(buf), 6)) + chunk(b'IEND', b''))


W_ = sys.stdout.write


def transmit():
    b64 = base64.b64encode(png()).decode()
    for i in range(0, len(b64), 4096):
        part = b64[i:i + 4096]
        more = 0 if i + 4096 >= len(b64) else 1
        W_(f"\033_Gi={IMG},f=100,a=t,q=2,m={more};{part}\033\\")


def place():
    rows = rows_for(cols)
    W_(f"\033_Ga=d,i={IMG}\033\\")                        # drop old placements
    W_(f"\033[1;1H\033_Gi={IMG},a=p,q=2,C=1,c={cols},r={rows}\033\\")
    W_("\033[?25l")
    sys.stdout.flush()


# ----------------------------------------------------------------- hit test
def cell_to_px(cx, cy):
    rows = rows_for(cols)
    if not (1 <= cx <= cols and 1 <= cy <= rows):
        return None
    return (int(((cx - 0.5) / cols) * W), int(((cy - 0.5) / rows) * H))


def cell_to_px_edge(cx, cy):
    rows = rows_for(cols)
    cx = max(1, min(cols, cx)); cy = max(1, min(rows, cy))
    return (int((cx / cols) * W), int((cy / rows) * H))


def probe(cx, cy):
    p = cell_to_px(cx, cy)
    if p is None:
        return f"cell ({cx},{cy}) outside image"
    (r, g, b), hue, rad = sample(*p)
    return (f"cell ({cx:2d},{cy:2d}) -> px ({p[0]:3d},{p[1]:3d})"
            f"  #{r:02x}{g:02x}{b:02x}  hue {hue*360:5.1f}  r={rad:.2f}")


def region(a, b):
    x0, y0 = cell_to_px_edge(min(a[0], b[0]), min(a[1], b[1]))
    x1, y1 = cell_to_px_edge(max(a[0], b[0]), max(a[1], b[1]))
    x1, y1 = max(x1, x0 + 1), max(y1, y0 + 1)
    n = s0 = s1 = s2 = 0
    step = max(1, (x1 - x0) // 40)
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            c = sample(x, y)[0]
            s0 += c[0]; s1 += c[1]; s2 += c[2]; n += 1
    r, g, bl = s0 // n, s1 // n, s2 // n
    return (f"drag ({a[0]},{a[1]})->({b[0]},{b[1]})  box {x1-x0}x{y1-y0}px"
            f"  avg #{r:02x}{g:02x}{bl:02x}")


def status(line1, line2=""):
    W_(f"\033[{STATUS};1H\033[K  {line1}\033[{STATUS+1};1H\033[K  {line2}")
    W_(f"\033[{STATUS+1};1H"); sys.stdout.flush()


HELP = "click=probe  drag=region  wheel/+-=zoom  q=quit"


def main():
    global cols
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    try:
        W_("\033[?1049h\033[2J\033[H")
        transmit()
        place()
        status(HELP, probe(1, 1))
        W_("\033[?1002h\033[?1006h"); sys.stdout.flush()
        buf, press, hovering = b"", None, (1, 1)
        while True:
            if not select.select([fd], [], [], 0.5)[0]:
                continue
            buf += os.read(fd, 4096)
            while buf:
                m = buf.find(b"\033[<")
                if m == 0:
                    e = -1
                    for i in range(3, len(buf)):
                        if buf[i] in b"Mm":
                            e = i; break
                    if e < 0:
                        break
                    try:
                        b, x, y = (int(v) for v in buf[3:e].split(b";"))
                    except ValueError:
                        buf = buf[e + 1:]; continue
                    rel = buf[e:e + 1] == b"m"
                    buf = buf[e + 1:]
                    motion, btn = bool(b & 32), b & 3
                    if b in (64, 65) or (b & 0x40 and (b & 3) in (0, 1)):
                        # wheel: 64 up / 65 down (also 66/67 horizontal)
                        if b in (64, 65):
                            cols = max(12, min(64, int(cols * (1.12 if b == 64 else 0.89))))
                            place()
                            status(HELP + f"   zoom c={cols}", probe(*hovering))
                        continue
                    if motion and press:                       # drag motion
                        press = (press[0], press[1], (x, y))
                        status(HELP, region(press[:2], (x, y)))
                    elif rel:                                  # release
                        if press:
                            status("released", region(press[:2], (x, y)))
                        press = None
                    elif btn == 0:                             # left press
                        press = (x, y, (x, y))
                        hovering = (x, y)
                        status("pressed" + ("" if cell_to_px(x, y) else " (outside)"),
                               probe(x, y))
                    continue
                if m > 0:
                    buf = buf[m:]
                    continue
                ch = buf[:1]; buf = buf[1:]
                if ch in (b"q", b"\x03", b"\x1b"):
                    return
                if ch in (b"+", b"="):
                    cols = max(12, min(64, cols + 4)); place(); status(HELP + f"   zoom c={cols}", probe(*hovering))
                elif ch in (b"-", b"_"):
                    cols = max(12, min(64, cols - 4)); place(); status(HELP + f"   zoom c={cols}", probe(*hovering))
    finally:
        W_("\033[?1002l\033[?1006l\033[?25h\033[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
