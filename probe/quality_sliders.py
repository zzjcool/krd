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
import sys, os, zlib, struct, base64, time, select, tty, termios, subprocess, threading, fcntl

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gray_probe as gp

CHUNK = 4096
IMAGE_ID = 1001
PLACEMENT_ID = 1
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CLIP = os.path.join(HERE, '..', 'docs', 'media', 'demo.mp4')

QUALITY = [100, 80, 60, 30, 0]
DOWNSCALE = [1, 2, 3, 4]                 # 1.0, 0.5, 0.33, 0.25
FPS = [30, 15, 10, 5, 2]
LABEL = {100: 'rgb + zlib (lossless)', 80: 'rgb 5-6-5 + zlib', 60: 'grey 8-bit png',
         30: 'grey 4-bit png', 0: 'black/white 1-bit'}


# ---------------------------------------------------------------- encoding

def resample(rows, w, h, factor):
    """Nearest neighbour by whole pixels: every channel of every factor-th pixel, not one channel
    of it. `row[0::3*factor]` takes the red channel only and hands the encoder 1/3 of a row, which
    it happily packs into a PNG whose header claims the full width -- a corrupt frame that a
    terminal renders as noise, and that a byte count will not notice.
    """
    if factor == 1:
        return rows, w, h
    tw, th = w // factor, h // factor
    out = []
    for row in rows[::factor][:th]:        # ceil() would hand the encoder one row too many
        buf = bytearray(tw * 3)
        for c in range(3):
            buf[c::3] = row[c::3 * factor][:tw]
        out.append(bytes(buf))
    return out, tw, th


def verify(payload, kind, w, h):
    """Every payload must decode to exactly the pixels the header declares."""
    if kind == 24:
        raw = zlib.decompress(payload)
        assert len(raw) == w * h * 3, f'rgb payload {len(raw)} != {w * h * 3}'
        return
    import struct as st
    assert payload[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
    hw, hh = st.unpack('>II', payload[16:24])
    depth, colour = payload[24], payload[25]
    assert (hw, hh) == (w, h), f'header {hw}x{hh} != {w}x{h}'
    i, idat = 8, b''
    while i < len(payload):
        ln = st.unpack('>I', payload[i:i+4])[0]
        if payload[i+4:i+8] == b'IDAT':
            idat += payload[i+8:i+8+ln]
        i += 12 + ln
    raw = zlib.decompress(idat)
    bits = 8 if colour == 0 else depth            # palette: the bit depth is the index width
    stride = 1 + (w * bits + 7) // 8
    assert len(raw) == h * stride, f'png payload {len(raw)} != {h * stride} ({stride}/row)' 


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
    """One frame as krd sends it: a=t to replace the pixels, a=p to place, all in one 2026 block.

    `a=T` (transmit and display) deletes the image and creates it again, which on a slow link the
    terminal can render halfway through -- that is the tearing. `a=t` swaps the pixels of the image
    the placement already points at, and DEC 2026 makes the terminal commit the whole thing in one
    repaint.
    """
    b64 = base64.b64encode(payload).decode()
    frame = ['\033[?2026h', '\033[3;2H']
    for i in range(0, len(b64), CHUNK):
        part = b64[i:i + CHUNK]
        more = 0 if i + CHUNK >= len(b64) else 1
        if i == 0:
            ctl = f'\033_Gi={IMAGE_ID},a=t,q=2,f={kind},m={more}'
            if dims:
                ctl += f',s={dims[0]},v={dims[1]},o=z'
            frame.append(ctl + ';' + part + '\033\\')
        else:
            frame.append(f'\033_Gm={more};{part}\033\\')
    frame.append(f'\033_Gi={IMAGE_ID},p={PLACEMENT_ID},a=p,q=2,C=1,c={cells_w},r={cells_h}\033\\')
    frame.append('\033[?2026l')
    out.emit(''.join(frame), kind='frame')


# ---------------------------------------------------------------- video

def clip_size(path):
    """The clip's own aspect, so the picture is not stretched into whatever shape the pane is."""
    try:
        out_ = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                               '-show_entries', 'stream=width,height', '-of', 'csv=p=0', path],
                              stdout=subprocess.PIPE, check=True).stdout.decode()
        w, h = (int(v) for v in out_.strip().split(',')[:2])
        return (w, h) if w > 0 and h > 0 else (16, 9)
    except Exception:
        return (16, 9)


def still(clip, w, h, at=3.0):
    cmd = ['ffmpeg', '-v', 'error', '-ss', str(at), '-i', clip, '-frames:v', '1',
           '-vf', f'scale={w}:{h}:flags=bilinear', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    buf = subprocess.run(cmd, stdout=subprocess.PIPE, check=True).stdout
    if len(buf) < w * h * 3:
        raise SystemExit(f'{clip}: no frame at {at}s')
    buf = buf[:w * h * 3]
    return [buf[i * w * 3:(i + 1) * w * 3] for i in range(h)]


def table(clip, src_w, src_h):
    """Every combination, measured on a real frame, with each payload checked against its header."""
    rows = still(clip, src_w, src_h)
    base_payload, base_kind, _ = encode(rows, src_w, src_h, 100)
    verify(base_payload, base_kind, src_w, src_h)
    base = len(base_payload)
    print(f'{os.path.basename(clip)} at {src_w}x{src_h}; 100 / 1.0 / 30 fps = '
          f'{human(base)}/frame, {human(base * 30)}/s\n')
    for factor in DOWNSCALE:
        r2, w2, h2 = resample(rows, src_w, src_h, factor)
        cells = []
        for quality in QUALITY:
            payload, kind, _ = encode(r2, w2, h2, quality)
            verify(payload, kind, w2, h2)
            cells.append(f'{quality:3d}:{human(len(payload)):>8s} {base / len(payload):6.2f}x')
        print(f'  --scale {("%.2f" % (1 / factor)).rstrip("0").rstrip("."):>4s} '
              f'({w2}x{h2})  ' + '   '.join(cells))
    print('\n  --fps 30/15/10/5/2 divide the same frame: 1.00x 2.00x 3.00x 6.00x 15.00x')
    r2, w2, h2 = resample(rows, src_w, src_h, 2)
    combined = len(encode(r2, w2, h2, 60)[0])
    print(f'  combined 60 / 0.5 / 15  = {base / combined * 2:5.2f}x fewer bytes '
          f'({human(combined)}/frame at {human(combined * 15)}/s)')


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


def draw_stats(screen, row, sent, seconds, write_ms, baseline, queued=0, dropped=0):
    rate = sum(sent[-60:]) / max(0.2, sum(seconds[-60:]))
    frame = sent[-1] if sent else 0
    ratio = baseline / rate if rate > 1 else 0
    blocked = sum(write_ms[-60:]) / max(1, len(write_ms[-60:]))
    screen.at(row, 1, f'  {human(frame):>9s}/frame   {human(int(rate)):>10s}/s   '
                      f'{ratio:5.2f}x smaller   write {blocked:4.1f} ms   '
                      f'queued {human(queued)}'
                      f'{f"  dropped {dropped}" if dropped else ""}')


TRACE = os.environ.get('KRD_PROBE_TRACE')


def trace(phase, t0):
    if TRACE:
        with open(TRACE, 'a') as f:
            f.write(f'{phase} {time.time() - t0:.4f}\n')


def human(n):
    if n >= 1 << 20:
        return f'{n / (1 << 20):.2f} MB'
    if n >= 1024:
        return f'{n / 1024:.1f} KB'
    return f'{n} B'


# ---------------------------------------------------------------- io that never blocks the keyboard

class Segment:
    __slots__ = ('kind', 'data', 'offset')

    def __init__(self, kind, data):
        self.kind, self.data, self.offset = kind, data, 0


class Out:
    """stdout in non-blocking mode, queued as whole segments, with text outranking pixels.

    Two problems this solves, both of which read as "the UI is frozen":

    - `flush()` on a pty blocks until the far end drains, so one frame on a slow link stopped the
      loop -- and with it the keyboard -- for as long as that frame took to leave.
    - Queuing alone is not enough: a key press then waits behind hundreds of KB of video. Text is
      feedback and frames are stale the moment a bar moves, so a key press drops every frame that
      has not started writing and lets the bars jump the queue.
    """

    def __init__(self, stream, limit=192 * 1024):
        self.fd = stream.fileno()
        self.segments = []
        self.limit = limit
        self.dropped = 0
        self.written = 0
        flags = fcntl.fcntl(self.fd, fcntl.F_GETFL)
        fcntl.fcntl(self.fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    def emit(self, text, kind='text'):
        if isinstance(text, str):
            text = text.encode()
        if kind == 'frame' and self.full():
            self.dropped += 1
            return False
        self.segments.append(Segment(kind, text))
        self.pump()
        return True

    def pump(self):
        while self.segments:
            seg = self.segments[0]
            try:
                n = os.write(self.fd, seg.data[seg.offset:])
            except BlockingIOError:
                return
            except OSError:
                self.segments.clear()
                return
            seg.offset += n
            self.written += n
            if seg.offset >= len(seg.data):
                self.segments.pop(0)

    def drop_frames(self):
        """A frame already half written has to finish (a truncated kitty transmission would leave
        the image unposted); everything behind it is stale and goes."""
        keep = []
        for i, seg in enumerate(self.segments):
            if seg.kind == 'frame' and (i > 0 or seg.offset == 0):
                self.dropped += 1
                continue
            keep.append(seg)
        self.segments = keep

    @property
    def queued(self):
        return sum(len(s.data) - s.offset for s in self.segments)

    def full(self):
        return self.queued > self.limit


class Reader:
    """ffmpeg frames in a one-slot mailbox: the loop never waits for the next frame, it takes the
    newest one or nothing at all. Reading inline made a stalled decoder look like a frozen UI."""

    def __init__(self, clip, w, h, fps=30):
        self.slot = None
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, args=(clip, w, h, fps), daemon=True)
        self.thread.start()

    def _run(self, clip, w, h, fps):
        try:
            for rows in source(clip, w, h, fps):
                if self.stop.is_set():
                    return
                with self.lock:
                    self.slot = rows
        except SystemExit:
            return

    def take(self):
        with self.lock:
            rows, self.slot = self.slot, None
        return rows


class Screen:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows

    def at(self, row, col, text):
        out.emit(f'\033[{row};{col}H\033[0m{text[:max(0, self.cols - 1)]}\033[K')


def main():
    argv = sys.argv[1:]
    flags = {'--cells', '--start', '--once', '--max-bytes'}
    positional = [a for i, a in enumerate(argv)
                  if not a.startswith('-') and not (i and argv[i - 1] in flags)]
    clip = os.path.abspath(positional[0]) if positional else os.path.abspath(DEFAULT_CLIP)
    if not os.path.exists(clip):
        raise SystemExit(f'{clip}: no such file')
    cells = argv[argv.index('--cells') + 1] if '--cells' in argv else None
    once = '--once' in argv
    start = argv[argv.index('--start') + 1] if '--start' in argv else '60,2,15'
    cap = int(argv[argv.index('--max-bytes') + 1]) if '--max-bytes' in argv else 48_000
    try:
        start_quality, start_space, start_fps = (float(v) for v in start.split(','))
    except ValueError:
        raise SystemExit('--start takes quality,space,fps -- e.g. --start 100,1,30')

    global out
    out = sys.stdout
    cols, rows, cell_w, cell_h = gp.pane()
    clip_w, clip_h = clip_size(clip)
    if cells:
        want_w, want_h = (int(v) for v in cells.split('x'))
        box_w = min(want_w, cols - 2)
    else:
        box_w = min(96, cols - 2)
    # fit the clip's aspect inside the space above the bars: a 720x466 clip in a 137-row pane used
    # to be stretched into a portrait box, which reads as "the display is broken"
    box_h_max = (min(63, rows - 10) if not cells else min(want_h, rows - 10))
    box_h = max(6, min(box_h_max, int(round(box_w * cell_w * clip_h / clip_w / cell_h))))
    src_w = max(64, int(box_w * cell_w)) // 2 * 2
    src_h = max(64, int(src_w * clip_h / clip_w)) // 2 * 2

    if once:
        table(clip, 768, 496)
        return

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

    reader = Reader(clip, src_w, src_h, fps=30)
    while reader.take() is None:                 # the first frame, once
        time.sleep(0.01)
    first_frame, baseline_frame = None, None
    # grab a still for the baseline while the mailbox keeps filling
    still_rows = still(clip, src_w, src_h)
    baseline_rate = len(encode(still_rows, src_w, src_h, 100)[0]) * 30

    out = Out(sys.stdout)
    out.emit('\033[?1000h\033[?1002h\033[?1006h\033[?25l')      # mouse press, drag, SGR, no cursor
    out.emit('\033[2J\033[H')
    screen.at(1, 1, f'quality sliders — {os.path.basename(clip)} {clip_w}x{clip_h} in '
                    f'{box_w}x{box_h} cells, {src_w}x{src_h} px source — drag the bars')
    screen.at(2, 1, '  ↑↓ pick · ←→ step · 0-9 jump · click or drag a bar · space pause · q quit')
    sent, seconds, write_ms = [], [], []
    current = 1                       # start on colour, the least destructive axis
    paused = False
    last_draw = 0.0
    due = 0.0
    next_read = 0.0
    last_send = 0.0
    pending = b''
    quit_now = False
    checked = set()
    key_at = 0.0
    budget = float(cap)         # a one-second token bucket, in bytes
    last_fill = time.time()
    paced = 0
    paced_ok = True             # a manual change may exceed the budget once, so it is felt: a slider
    last_change = 0.0           # that looks dead on a slow link is worse than one late frame
    budget = float(cap)          # a one-second token bucket, in bytes
    last_fill = time.time()
    paced = 0
    paced_ok = True          # a manual change may exceed the budget once, so it is felt
                        # (the alternative is a slider that appears dead on a slow link)
    last_change = 0.0

    budget = float(cap)         # a one-second token bucket, in bytes
    last_fill = time.time()
    paced = 0
    paced_ok = True             # a manual change may go over the budget once, so the
    last_change = 0.0           # slider never looks dead on a slow link
    try:
        while True:
            # ---- keys first, always, and never after a blocking write
            t0 = time.time()
            ready = select.select([fd], [], [], 0.005)[0]
            trace('select', t0)
            while ready and select.select([fd], [], [], 0)[0]:
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
                trace('key', time.time())
                key_at = time.time()
                out.drop_frames()        # any key at all: what is queued is now stale
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
                            last_draw = 0.0
                    elif len(data) >= 3 and data[1:2] == b'[':
                        key = data[2:3]
                        if key in (b'A', b'B', b'C', b'D'):
                            last_draw = 0.0
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
                    last_draw = 0.0
                elif data[:1] in (b'j', b'J'):
                    current = (current + 1) % len(bars)
                    last_draw = 0.0
                elif data[:1] in (b'k', b'K'):
                    current = (current - 1) % len(bars)
                    last_draw = 0.0
                elif data[:1] in (b'l', b'L'):
                    bars[current].nudge(1)
                elif data[:1] in (b'h', b'H'):
                    bars[current].nudge(-1)
                elif data[:1].isdigit():
                    bars[current].index = min(len(bars[current].steps) - 1, int(data[:1]))
                if data[:1] in b'hHlL0123456789' or data.startswith(b'\033[CD'):
                    due = 0.0
                    last_draw = 0.0                  # redraw the bars immediately, not in 200 ms

            if quit_now:
                break

            # ---- output: give the queue a chance to drain, never wait for it
            t0 = time.time(); out.pump(); trace('pump', t0)

            # ---- frames: the mailbox hands over the newest frame or nothing at all
            now = time.time()
            t0 = time.time(); rows = reader.take() if not paused else None; trace('take', t0)
            budget = min(cap, budget + (now - last_fill) * cap)
            last_fill = now
            if rows is not None and (now - last_send >= 1.0 / bars[2].value or due <= 0):
                if out.full():
                    out.dropped += 1                 # behind: dropping a frame beats freezing
                else:
                    factor = bars[1].value
                    t0 = time.time()
                    rows, tw, th = resample(rows, src_w, src_h, factor)
                    trace('resample', t0)
                    t0 = time.time()
                    payload, kind, dims = encode(rows, tw, th, bars[0].value)
                    trace('encode', t0)
                    wire = len(payload) * 4 // 3 + 64   # base64 plus the escape around it
                    if wire > budget and paced_ok and (now - last_change) > 0.5:
                        paced += 1                   # the budget says no; the bars stay responsive
                    else:
                        if (bars[0].value, factor) not in checked:
                            try:
                                verify(payload, kind, tw, th)
                            except AssertionError as e:
                                out.emit('\033[?2026l\033_Ga=d,d=A,q=2\033\\'
                                         '\033[?1000l\033[?1002l\033[?1006l\033[?25h\033[0m\r\n')
                                out.pump()
                                time.sleep(0.2)
                                termios.tcsetattr(fd, termios.TCSADRAIN, saved)
                                raise SystemExit(f'quality {bars[0].value} at scale 1/{factor}: {e}')
                            checked.add((bars[0].value, factor))
                        out.emit('\033[3;2H')
                        wrote = time.time()
                        transmit(kind, payload, box_w, box_h, dims)
                        out.pump()
                        trace('send', wrote)
                        write_ms.append((time.time() - wrote) * 1000)
                        sent.append(len(payload))
                        seconds.append(1.0 / bars[2].value)
                        budget -= wire
                        last_send = now
                        due = 1.0

            if now - last_draw > 0.2:
                last_draw = now
                t0 = time.time()
                out.emit('\033[?2026h')
                draw_bars(screen, bars, bar_top + 1, bar_width, current)
                draw_stats(screen, bar_top + 5, sent, seconds, write_ms, baseline_rate or 1,
                           out.queued, out.dropped)
                screen.at(bar_top + 6, 1, f'  {len(sent)} frames sent · '
                                          f'{"paused" if paused else "playing"} · '
                                          f'paced {human(cap)}/s · {paced} held back')
                out.emit('\033[?2026l')
                trace('draw', t0)
                if key_at:
                    trace('latency', key_at)
                    key_at = 0.0
    except KeyboardInterrupt:
        pass
    finally:
        # close any dangling 2026 block first: an unclosed one freezes the terminal's drawing
        out.emit('\033[?2026l\033_Ga=d,d=A,q=2\033\\'
                 '\033[?1000l\033[?1002l\033[?1006l\033[?25h\033[0m\n')
        deadline = time.time() + 1.0                 # let the farewell leave before the fd closes
        while out.queued and time.time() < deadline:
            out.pump()
            time.sleep(0.02)
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == '__main__':
    main()
