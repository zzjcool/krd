#!/usr/bin/env python3
"""Show the three axes that cost bytes -- colour depth, space, time -- on a looping video.

One picture with a label is not enough to judge this: the colour axis needs a still you can stare
at, the time axis needs motion, and the space axis needs both. So this walks four phases and stops
at each setting long enough to see what it did:

    A  colour   100 / 80 / 60 / 30 / 0     still frame; 100 = lossless RGB, 0 = 1-bit black/white
    B  space    1.0 / 0.5 / 0.25           still frame, upscaled by the terminal to the same box
    C  time     30 / 15 / 8 / 4 fps        playing, same pixels as A100
    D  combined 60 / 0.5 / 15 fps          playing, the recommended setting for a slow link

Every step prints bytes/frame, KB/s and the ratio against A100 at 30 fps, so "how much did that
cost me" is measured, not estimated. The numbers are what this machine and this terminal actually
sent; the encoders are the same ones `probe/gray_probe.py` measures.

Usage:

    python3 probe/quality_demo.py                       # docs/media/demo.mp4, loop forever
    python3 probe/quality_demo.py clip.mp4              # any video ffmpeg can read
    python3 probe/quality_demo.py --cells 100x32        # bigger box
    python3 probe/quality_demo.py --once                # one pass, print the table, exit (no video)

Requires ffmpeg on PATH (decode/scale/resample only -- the encoders are pure Python stdlib).
"""
import sys, os, zlib, struct, base64, time, subprocess, array, fcntl, termios

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gray_probe as gp                       # png_grey / png_palette / 5-6-5 tables / pane()

CHUNK = 4096
IMAGE_ID = 1000
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CLIP = os.path.join(HERE, '..', 'docs', 'media', 'demo.mp4')


# ---------------------------------------------------------------- encoders (the three axes)

def encode_rgb(rows, w, h, quality):
    """quality 100/80 -> RGB + zlib, 60/30/0 -> greyscale PNG at that bit depth."""
    if quality >= 80:
        if quality >= 100:
            payload = zlib.compress(b''.join(rows), 6)
        else:
            quantised = []
            for row in rows:
                buf = bytearray(row)
                buf[0::3] = row[0::3].translate(gp._TR_5)
                buf[1::3] = row[1::3].translate(gp._TR_6)
                buf[2::3] = row[2::3].translate(gp._TR_5)
                quantised.append(bytes(buf))
            payload = zlib.compress(b''.join(quantised), 6)
        return payload, 24, (w, h)
    grey = [row[1::3] for row in rows]                      # green channel: luma proxy, free
    if quality >= 60:
        return gp.png_grey(grey, w, h), 100, None
    if quality >= 30:
        return gp.png_palette(grey, w, h, 4), 100, None
    return gp.png_palette(grey, w, h, 1), 100, None


def downscale(rows, factor):
    """Nearest neighbour: the terminal upscales to the same cell box, which is the point."""
    return [row[0::factor] for row in rows[0::factor]]


def transmit(kind, payload, cells_w, cells_h, dims=None):
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
    out.flush()
    return len(b64)


# ---------------------------------------------------------------- video

def stream(clip, w, h, fps):
    """Raw RGB frames, looping forever, as ffmpeg decodes them."""
    cmd = ['ffmpeg', '-v', 'error', '-stream_loop', '-1', '-i', clip,
           '-vf', f'scale={w}:{h}:flags=bilinear', '-r', str(fps),
           '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    size = w * h * 3
    try:
        while True:
            buf = proc.stdout.read(size)
            if len(buf) < size:
                return
            yield [buf[i * w * 3:(i + 1) * w * 3] for i in range(h)]
    finally:
        proc.kill()


def still(clip, w, h, at=3.0):
    cmd = ['ffmpeg', '-v', 'error', '-ss', str(at), '-i', clip, '-frames:v', '1',
           '-vf', f'scale={w}:{h}:flags=bilinear', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    buf = subprocess.run(cmd, stdout=subprocess.PIPE, check=True).stdout
    size = w * h * 3
    if len(buf) < size:
        raise SystemExit(f'{clip}: could not grab a frame at {at}s')
    buf = buf[:size]
    return [buf[i * w * 3:(i + 1) * w * 3] for i in range(h)]


# ---------------------------------------------------------------- screen

class Screen:
    def __init__(self, cols, rows, cell_w, cell_h):
        self.cols, self.rows, self.cw, self.ch = cols, rows, cell_w, cell_h

    def at(self, row, col, text, dim=False):
        out.write(f'\033[{row};{col}H\033[0m' + ('\033[2m' if dim else '') +
                  text[:max(0, self.cols - col)] + '\033[0m')


def human(n):
    if n >= 1 << 20:
        return f'{n / (1 << 20):.1f} MB'
    if n >= 1024:
        return f'{n / 1024:.1f} KB'
    return f'{n} B'


# ---------------------------------------------------------------- phases

def describe(quality):
    return {100: 'rgb + zlib', 80: 'rgb 5-6-5 + zlib', 60: 'grey 8-bit png',
            30: 'grey 4-bit png', 0: 'black/white 1-bit png'}.get(quality, '?')


def phases(box_w, box_h, clip):
    """(axis, label, seconds, fps, quality, scale); seconds None = hold this still frame."""
    plan = []
    for quality in (100, 80, 60, 30, 0):
        plan.append(('colour', f'--quality {quality}   {describe(quality)}', None, 0, quality, 1.0))
    for scale in (1.0, 0.5, 0.25):
        plan.append(('space', f'--scale {scale}   {int(box_w * cell_w * scale)}x'
                              f'{int(box_h * cell_h * scale)} px, upscaled by the terminal',
                     None, 0, 100, scale))
    for fps in (30, 15, 8, 4):
        plan.append(('time', f'--fps {fps}', 2.5, fps, 100, 1.0))
    plan.append(('combined', '--quality 60 --scale 0.5 --fps 15   (recommended for a slow link)',
                 6.0, 15, 60, 0.5))
    return plan


def main():
    argv = sys.argv[1:]
    flags = {'--once', '--cells'}
    positional = [a for i, a in enumerate(argv)
                  if not a.startswith('-') and not (i and argv[i - 1] in flags)]
    clip = os.path.abspath(positional[0]) if positional else os.path.abspath(DEFAULT_CLIP)
    if not os.path.exists(clip):
        raise SystemExit(f'{clip}: no such file')
    once = '--once' in argv
    cells = '100x32'
    if '--cells' in argv:
        cells = argv[argv.index('--cells') + 1]
    want_w, want_h = (int(v) for v in cells.split('x'))

    cols, rows, cw, ch = gp.pane()
    # the box in cells, then the pixels that fill it at scale 1.0
    box_w = min(want_w, cols - 2)
    box_h = min(want_h, rows - 9)
    src_w = max(64, int(box_w * cw)) // 2 * 2
    src_h = max(64, int(box_h * ch)) // 2 * 2
    if once:
        # no pane to measure against: pretend a 137x60 pane with 8x16 cells
        cols, rows, cw, ch = 137, 60, 8, 16
        box_w, box_h = min(want_w, cols - 2), min(want_h, rows - 9)
        src_w, src_h = int(box_w * cw) // 2 * 2, int(box_h * ch) // 2 * 2

    global out
    out = sys.stdout
    global cell_w, cell_h
    cell_w, cell_h = cw, ch
    screen = Screen(cols, rows, cw, ch)

    frozen = still(clip, src_w, src_h, at=3.0)
    baseline = len(encode_rgb(frozen, src_w, src_h, 100)[0])

    if once:
        print(f'{os.path.basename(clip)} at {src_w}x{src_h} in a {box_w}x{box_h} cell box')
        print(f'baseline A100 30 fps = {human(baseline)}/frame, {human(baseline * 30)}/s\n')
        for axis, label, seconds, fps, quality, scale in phases(box_w, box_h, clip):
            w, h = int(src_w * scale) // 2 * 2, int(src_h * scale) // 2 * 2
            frame = downscale(frozen, int(round(1 / scale))) if scale != 1.0 else frozen
            frame = [row[:w * 3] for row in frame[:h]]
            payload, _, _ = encode_rgb(frame, w, h, quality)
            per_s = len(payload) * (fps or 30)
            print(f'  {axis:9s} {label[:52]:52s} {human(len(payload)):>8s}/frame  '
                  f'{human(per_s):>9s}/s  {baseline * 30 / per_s:5.2f}x smaller')
        print('\n(the terminal also pays 4/3 for base64; ratios are unaffected)')
        return

    out.write('\033[2J\033[H')
    screen.at(1, 1, 'quality demo: the three axes, measured on the wire')
    out.flush()

    latency = 0.0
    try:
        while True:
            for axis, label, seconds, fps, quality, scale in phases(box_w, box_h, clip):
                w, h = int(src_w * scale) // 2 * 2, int(src_h * scale) // 2 * 2
                header = {'colour': 'A colour depth -- a still frame, 100 = lossless, 0 = 1-bit',
                          'space': 'B spatial resolution -- the terminal upscales to the same box',
                          'time': 'C frame rate -- same pixels, fewer of them',
                          'combined': 'D the recommended setting for a slow link'}[axis]
                screen.at(2, 1, header, dim=True)
                screen.at(3, 1, f'{label:<24s}')
                out.flush()

                if seconds is None:                     # still frame: hold this setting
                    frame = downscale(frozen, int(round(1 / scale))) if scale != 1.0 else frozen
                    frame = [row[:w * 3] for row in frame[:h]]
                    payload, kind, dims = encode_rgb(frame, w, h, quality)
                    started = time.time()
                    out.write(f'\033[5;2H')
                    transmit(kind, payload, box_w, box_h, dims=dims)
                    sent = 1
                    against = 'quality 100' if axis == 'colour' else 'scale 1.0'
                    while time.time() - started < 1.2:  # hold, and keep the numbers live
                        screen.at(5 + box_h + 1, 1,
                                  f'{human(len(payload)):>8s}/frame  {baseline / len(payload):5.2f}x'
                                  f' smaller than {against}')
                        out.flush()
                        time.sleep(0.2)
                else:                                    # playing: real frames from ffmpeg
                    interval = 1.0 / fps
                    deadline = time.time() + seconds
                    sent = 0
                    moving = 0
                    for frame in stream(clip, w, h, fps):
                        nxt = time.time() + interval
                        payload, kind, dims = encode_rgb(frame, w, h, quality)
                        out.write(f'\033[5;2H')
                        transmit(kind, payload, box_w, box_h, dims=dims)
                        sent += 1
                        moving += len(payload)
                        rate = moving / max(0.001, time.time() - (deadline - seconds))
                        if axis == 'time':
                            note = f'{30 / max(1, fps):5.2f}x fewer frames than 30 fps'
                        else:
                            note = f'{baseline * 30 / max(1, rate):5.2f}x smaller than A100 at 30 fps'
                        screen.at(5 + box_h + 1, 1,
                                  f'{human(len(payload)):>8s}/frame  {human(int(rate)):>9s}/s  {note}')
                        out.flush()
                        if time.time() >= deadline:
                            break
                        time.sleep(max(0, nxt - time.time()))
    except KeyboardInterrupt:
        pass
    finally:
        out.write('\033_Ga=d,d=A,q=2\033\\\033[0m\n')
        out.flush()


if __name__ == '__main__':
    main()
