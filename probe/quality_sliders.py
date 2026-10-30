#!/usr/bin/env python3
"""A looping video with three sliders you drive yourself: colour, space, time.

The point is to feel the trade instead of reading a table. The clip plays while you move the bars,
each move re-encodes the next frame for real, and the numbers under the bars are what was actually
put on the wire a moment ago -- not an estimate.

    colour   --quality  100 (lossless rgb) · 80 (5-6-5) · 60 (8-bit grey) · 30 (4-bit grey) · 0 (1-bit)
    space    --scale    1.0 · 0.5 · 0.33 · 0.25        (the terminal upscales to the same box)
    time     --fps      30 · 15 · 10 · 5 · 2

Controls, because a slider you cannot reach is a table with extra steps:

    ↑ ↓  or  j k      pick a bar
    ← →  or  h l      one step along the bar      0-9  jump · space toggles play/pause
    mouse             click or drag anywhere on a bar (SGR 1002/1006), the usual way to use a slider
    q                 quit

Usage:

    python3 probe/quality_sliders.py                    # docs/media/demo.mp4
    python3 probe/quality_sliders.py clip.mov --cells 90x28
    python3 probe/quality_sliders.py --still 5.0        # start on a frame that has text in it

Requires ffmpeg on PATH (decode/resample only); the encoders are pure stdlib.
"""
import sys, os, zlib, struct, base64, time, select, tty, termios, subprocess, array, fcntl

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gray_probe as gp

CHUNK = 4096
IMAGE_ID = 1001
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CLIP = os.path.join(HERE, '..', 'docs', 'media', 'demo.mp4')

QUALITY = [100, 80, 60, 30, 0]
DOWNSCALE = [1, 2, 3, 4]                 # 1.0, 0.5, 0.33, 0.25
FPS = [30, 15, 10, 5, 2]
LABEL = {100: 'rgb + zlib (lossless)', 80: 'rgb 5-6-5 + zlib', 60: 'grey 8-bit png',
         30: 'grey 4-bit png', 0: 'black/white 1-bit'}


# ---------------------------------------------------------------- encoding

def resample(rows, w, h, factor):
    if factor == 1:
        return rows, w, h
    tw, th = w // factor, h // factor
    out = [row[0::3 * factor][:tw * 3] for row in rows[0::factor]]
    return out, tw, th


def encode(rows, w, h, quality):
    """-> (payload, kitty f=, (s,v) for f=24 else None)."""
    if quality >= 80:
        if quality < 100:
            quant = []
            for row in rows:
                buf = bytearray(row)
                buf[0::3] = row[0::3].translate(gp._TR_5)
                buf[1::3] = row[1::3].translate(gp._TR_6)
                buf[2::3] = row[2::3].translate(gp._TR_5)
                quant.append(bytes(buf))
            rows = quant
        return zlib.compress(b''.join(rows), 6), 24, (w, h)
    grey = [row[1::3] for row in rows]
    if quality >= 60:
        return gp.png_grey(grey, w, h), 100, None
    if quality >= 30:
        return gp.png_palette(grey, w, h, 4), 100, None
    return gp.png_palette(grey, w, h, 1), 100, None


def transmit(kind, payload, cells_w, cells_h, dims):
    b64 = base64.b64encode(payload).decode()
    first = True
    for i in range(0, len(b64), CHUNK):
        part = b64[i:i + CHUNK]
        more = 0 if i + CHUNK >= len(b64) else 1
        if first:
            ctl = f'\033_Gi={IMAGE_ID},a=T,q=2,f={kind},c={cells_w},r={cells_h},C=1,m={more}'
            if dims:
                ctl += f',s={dims[0]},v={dims[1]},o=z'
            out.write(ctl + ';' + part + '\033\\')
            first = False
        else:
            out.write(f'\033_Gm={more};{part}\033\\')


# ---------------------------------------------------------------- video

def source(clip, w, h, fps=30):
    cmd = ['ffmpeg', '-v', 'error', '-stream_loop', '-1', '-i', clip,
           '-vf', f'scale={w}:{h}:flags=bilinear', '-r', str(fps),
           '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    size = w * h * 3
    while True:
        buf = proc.stdout.read(size)
        if len(buf) < size:
            proc.kill()
            raise SystemExit(f'{clip}: ffmpeg stopped producing frames')
        yield [buf[i * w * 3:(i + 1) * w * 3] for i in range(h)]


# ---------------------------------------------------------------- sliders

class Bar:
    def __init__(self, name, flag, steps, fmt):
        self.name, self.flag, self.steps, self.fmt = name, flag, steps, fmt
        self.index = 0

    @property
    def value(self):
        return self.steps[self.index]

    def nudge(self, delta):
        self.index = max(0, min(len(self.steps) - 1, self.index + delta))

    def set_fraction(self, fraction):
        """Click at `fraction` of the bar -> the nearest step, so dragging lands where it looks."""
        self.index = max(0, min(len(self.steps) - 1,
                                int(round(fraction * (len(self.steps) - 1)))))

    def text(self, width):
        pos = int(round(self.index * (width - 1) / max(1, len(self.steps) - 1)))
        return '█' * pos + '◆' + '░' * (width - 1 - pos)


def draw_bars(screen, bars, top, width, current):
    for i, bar in enumerate(bars):
        row = top + i
        mark = '▸' if i == current else ' '
        screen.at(row, 1, f'{mark} {bar.name:<7s} {bar.text(width)}  {bar.flag} {bar.fmt(bar.value)}')


def draw_stats(screen, row, sent, seconds, write_ms, baseline):
    rate = sum(sent[-60:]) / max(0.2, sum(seconds[-60:]))
    frame = sent[-1] if sent else 0
    ratio = baseline / rate if rate > 1 else 0
    blocked = sum(write_ms[-60:]) / max(1, len(write_ms[-60:]))
    screen.at(row, 1, f'  {human(frame):>9s}/frame   {human(int(rate)):>10s}/s   '
                      f'{ratio:5.2f}x smaller than 100 / 1.0 / 30 fps   '
                      f'write {blocked:4.1f} ms')


def human(n):
    if n >= 1 << 20:
        return f'{n / (1 << 20):.2f} MB'
    if n >= 1024:
        return f'{n / 1024:.1f} KB'
    return f'{n} B'


# ---------------------------------------------------------------- main

class Screen:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows

    def at(self, row, col, text):
        out.write(f'\033[{row};{col}H\033[0m{text[:max(0, self.cols - 1)]}\033[K')


def main():
    argv = sys.argv[1:]
    flags = {'--cells', '--start'}
    positional = [a for i, a in enumerate(argv)
                  if not a.startswith('-') and not (i and argv[i - 1] in flags)]
    clip = os.path.abspath(positional[0]) if positional else os.path.abspath(DEFAULT_CLIP)
    if not os.path.exists(clip):
        raise SystemExit(f'{clip}: no such file')
    cells = argv[argv.index('--cells') + 1] if '--cells' in argv else None
    start = argv[argv.index('--start') + 1] if '--start' in argv else '60,2,15'
    try:
        start_quality, start_space, start_fps = (float(v) for v in start.split(','))
    except ValueError:
        raise SystemExit('--start takes quality,space,fps -- e.g. --start 100,1,30')

    global out
    out = sys.stdout
    cols, rows, cell_w, cell_h = gp.pane()
    if cells:
        want_w, want_h = (int(v) for v in cells.split('x'))
        box_w, box_h = min(want_w, cols - 2), min(want_h, rows - 10)
    else:
        box_w, box_h = min(96, cols - 2), max(8, rows - 10)
    src_w = max(64, int(box_w * cell_w)) // 2 * 2
    src_h = max(64, int(box_h * cell_h)) // 2 * 2

    screen = Screen(cols, rows)
    bars = [Bar('colour', '--quality', QUALITY, lambda v: f'{v:>3d}   {LABEL[v]}'),
            Bar('space', '--scale', DOWNSCALE,
                lambda v: f'{("%.2f" % (1 / v)).rstrip("0").rstrip("."):>4s}  '
                          f'{src_w // v}x{src_h // v} px'),
            Bar('time', '--fps', FPS, lambda v: f'{v:>3d}')]
    # start where a slow link can actually keep up; drag right if yours can. 100/1.0/30 is ~325 KB/s
    # of base64, which an ssh pty takes but the far end buffers for seconds.
    for bar, want in zip(bars, (start_quality, start_space, start_fps)):
        bar.index = min(range(len(bar.steps)),
                        key=lambda i: abs(bar.steps[i] - (want if bar is not bars[2] else want)))

    bar_top = 4 + box_h
    bar_width = max(8, min(36, cols - 40))

    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    out.write('\033[?1000h\033[?1002h\033[?1006h\033[?25l')      # mouse press, drag, SGR, no cursor
    out.write('\033[2J\033[H')
    screen.at(1, 1, f'quality sliders — {os.path.basename(clip)} — video loops while you drag')
    screen.at(2, 1, '  ↑↓ pick · ←→ step · 0-9 jump · click or drag a bar · space pause · q quit')
    out.flush()

    frames = source(clip, src_w, src_h, fps=30)
    sent, seconds, write_ms = [], [], []
    first_frame = next(frames)
    baseline_rate = len(encode(first_frame, src_w, src_h, 100)[0]) * 30
    current = 1                       # start on colour, the least destructive axis
    paused = False
    last_draw = 0.0
    due = 0.0
    next_read = 0.0
    last_send = 0.0
    pending = b''
    quit_now = False

    try:
        while True:
            # ---- input, non-blocking
            while select.select([fd], [], [], 0)[0]:
                pending += os.read(fd, 64)
            while pending:
                if pending[0:1] == b'\033' and len(pending) < 3:
                    break                                    # wait for the rest of the escape
                if pending.startswith(b'\033[<'):
                    end = pending.find(b'M')
                    end = pending.find(b'm') if end < 0 else end
                    if end < 0:
                        break
                    data, pending = pending[:end + 1], pending[end + 1:]
                elif pending.startswith(b'\033['):
                    data, pending = pending[:3], pending[3:]
                else:
                    data, pending = pending[:1], pending[1:]
                if data[:1] == b'\033':
                    if data.startswith(b'\033[<'):
                        try:
                            button, x, y = data[3:].decode().rstrip('Mm').split(';')
                            button, x, y = int(button), int(x), int(y)
                        except ValueError:
                            continue
                        index = y - (bar_top + 1)
                        if 0 <= index < len(bars) and x >= 11:       # a click or drag on a bar
                            bars[index].set_fraction(max(0.0, min(0.999, (x - 11) / bar_width)))
                            current = index
                            due = 0.0                                # show it now, not next tick
                    elif len(data) >= 3 and data[1:2] == b'[':
                        key = data[2:3]
                        if key == b'A':
                            current = (current - 1) % len(bars)
                        elif key == b'B':
                            current = (current + 1) % len(bars)
                        elif key == b'C':
                            bars[current].nudge(1)
                        elif key == b'D':
                            bars[current].nudge(-1)
                    else:
                        break                                        # lone Esc: quit
                elif data in (b'q', b'Q'):
                    quit_now = True
                    break
                elif data == b' ':
                    paused = not paused
                elif data[:1] in (b'j', b'J'):
                    current = (current + 1) % len(bars)
                elif data[:1] in (b'k', b'K'):
                    current = (current - 1) % len(bars)
                elif data[:1] in (b'l', b'L'):
                    bars[current].nudge(1)
                elif data[:1] in (b'h', b'H'):
                    bars[current].nudge(-1)
                elif data[:1].isdigit():
                    bars[current].index = min(len(bars[current].steps) - 1, int(data[:1]))
                if data[:1] in b'hHlL0123456789' or data.startswith(b'\033[CD'):
                    due = 0.0

            if quit_now:
                break

            # ---- frames: read at the clip's own 30 fps so time keeps moving, draw at the bar's fps
            now = time.time()
            if not paused and now >= next_read:
                rows = next(frames)
                next_read = max(next_read + 1 / 30.0, now - 0.3)
                # a change asked for a redraw; otherwise send at most `fps` per second, and never
                # catch up in a burst (a backlog would make the fps bar a lie)
                if now - last_send >= 1.0 / bars[2].value or due <= 0:
                    rows, tw, th = resample(rows, src_w, src_h, bars[1].value)
                    payload, kind, dims = encode(rows, tw, th, bars[0].value)
                    out.write('\033[3;2H')
                    wrote = time.time()
                    transmit(kind, payload, box_w, box_h, dims)
                    out.flush()
                    write_ms.append((time.time() - wrote) * 1000)
                    sent.append(len(payload))
                    seconds.append(1.0 / bars[2].value)
                    last_send = now
                    due = 1.0
            else:
                time.sleep(0.004)

            if now - last_draw > 0.2:
                last_draw = now
                draw_bars(screen, bars, bar_top + 1, bar_width, current)
                draw_stats(screen, bar_top + 5, sent, seconds, write_ms, baseline_rate or 1)
                screen.at(bar_top + 6, 1, f'  {len(sent)} frames sent · '
                                          f'{"paused" if paused else "playing"}')
                out.flush()
    except KeyboardInterrupt:
        pass
    finally:
        out.write('\033_Ga=d,d=A,q=2\033\\\033[?1000l\033[?1002l\033[?1006l\033[?25h\033[0m\n')
        out.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == '__main__':
    main()
