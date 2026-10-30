#!/usr/bin/env python3
"""Does this terminal accept grayscale / paletted PNGs through `f=100`, and what do they cost?

`f=` only has 24 (RGB), 32 (RGBA) and 100 (PNG). krd sends RGB + `o=z`, which cannot say "one byte
per pixel": a grey page costs up to 3x more on the wire than it has to. PNG *can* carry 8-bit
greyscale (colour type 0) and 1/2/4-bit palettes (colour type 3), and kitty's spec says "any PNG
image can be transmitted directly" -- but that is kitty's promise, not rex's or Ghostty's.

The probe draws one card four ways and prints the byte cost of each:

    A  f=24 + o=z        today's path
    B  f=100 PNG        8-bit greyscale        (colour type 0)
    C  f=100 PNG        1-bit palette          (colour type 3, 2 entries)
    D  f=100 PNG        4-bit palette          (colour type 3, 16 entries)
    E  grey8 + o=z       not sendable today: the same pixels as B without PNG's ~60 B/tile framing,
    -  rgb + 5-6-5       shipped (#59), for incompressible tiles only

Usage:

    python3 probe/gray_probe.py                    # cards + tables in the terminal you are testing
    python3 probe/gray_probe.py --no-images        # tables only, does not draw anything (fast)
    python3 probe/gray_probe.py --image shot.png   # measure a real screenshot instead of the card
    python3 probe/gray_probe.py --tiles 100        # per-tile sampling budget (default 300)

What the numbers already told us (measured, not guessed):

    * a 2880x5120 screenshot: whole image grey 2.98x, 1-bit 22.8x -- but *per tile* 0.76x and 0.73x,
      i.e. PNG framing (signature + IHDR + IEND + a filter byte per row) costs more than a flat
      terminal tile saves. PNG per small tile is a dead end; per region it is not.
    * the synthetic card is mostly flat too, so it understates packing. `--image` is the number
      that decides anything; the card exists to answer "does this terminal render it".

Two ways this probe lied before it was fixed, kept as a warning:

    * `o=z` must inflate to exactly `s*v*bytes_per_pixel`. A PNG-style filter byte per row makes it
      300 bytes longer for a 480x300 card, and the terminal answers `EINVAL: invalid`.
    * per-pixel Python over a 14.7 MP screenshot takes 27 s. Everything here now works on whole
      rows with slices and `bytes.translate`, and the per-tile table samples tiles.

Only stdlib, nothing to install. Images are deleted on exit.
"""
import sys, os, zlib, struct, base64, time, select, tty, termios, array, fcntl

W, H = 480, 300                 # the synthetic card, in pixels
TILE_W, TILE_H = 136, 132       # krd's tile at 17x33 px cells and --tile 8x4
CHUNK = 4096                    # kitty's documented base64 chunk size

# grey -> 5/6/5, and grey -> palette index, as 256-entry byte tables so the work stays in C
_TR_5 = bytes(((v >> 3) << 3) | ((v >> 3) >> 2) for v in range(256))     # red/blue
_TR_6 = bytes(((v >> 2) << 2) | ((v >> 2) >> 4) for v in range(256))     # green


def _index_table(levels):
    return bytes(round(v * (levels - 1) / 255) for v in range(256))


# ---------------------------------------------------------------- the test card

def _rnd(seed):
    return (seed * 1103515245 + 12345) % 2147483648


GLYPH = {  # 5x7, the only letters the card uses
    'A': ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    'B': ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    'C': ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    'D': ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
}


def card():
    """Grey rows, 1 byte per pixel, deterministic."""
    px = [bytearray([250] * W) for _ in range(H)]

    for i in range(16):                                   # 16-step ramp
        v = round(i * 255 / 15)
        for y in range(8, 52):
            for x in range(i * W // 16, (i + 1) * W // 16):
                px[y][x] = v

    for y in range(60, 80):                               # 1px checker: worst case for scaling
        for x in range(10, W - 10):
            px[y][x] = 255 if (x + y) % 2 else 0

    for row in range(10):                                 # text-like bars, one antialiased row each
        y0 = 88 + row * 15
        x, seed = 14, row * 977 + 13
        while x < W - 40:
            seed = _rnd(seed)
            run = 4 + seed % 10
            for xx in range(x, min(W - 14, x + run)):
                px[y0][xx] = 25
            x += run + 3
        for xx in range(14, W - 14):
            px[y0 + 1][xx] = 150                          # the AA fringe a glyph edge has

    for y in range(H):                                    # border, mid grey
        px[y][0] = px[y][1] = px[y][W - 1] = px[y][W - 2] = 128
    for x in range(W):
        px[0][x] = px[1][x] = px[H - 1][x] = px[H - 2][x] = 128
    return [bytes(row) for row in px]


def stamp(grey, letter, x0, y0, scale=8):
    for row, bits in enumerate(GLYPH[letter]):
        for col, bit in enumerate(bits):
            if bit != '1':
                continue
            for dy in range(scale):
                y = y0 + row * scale + dy
                if not (0 <= y < len(grey)):
                    continue
                line = bytearray(grey[y])
                for dx in range(scale):
                    x = x0 + col * scale + dx
                    if 0 <= x < len(line):
                        line[x] = 0
                grey[y] = bytes(line)


# ---------------------------------------------------------------- planes

def load_png(path):
    """Decode an 8-bit non-interlaced PNG into grey rows (1 byte/pixel).

    The grey plane is the green channel: it is the usual luma proxy and slicing it is free, where
    the exact weights cost a Python loop over every pixel -- 27 s on a 14.7 MP screenshot.
    """
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit(f'{path}: not a PNG')
    i, w, h, depth, colour, interlace, idat = 8, 0, 0, 0, 0, 0, b''
    while i < len(data):
        ln = struct.unpack('>I', data[i:i + 4])[0]
        tag, chunk = data[i + 4:i + 8], data[i + 8:i + 8 + ln]
        if tag == b'IHDR':
            w, h = struct.unpack('>II', chunk[:8])
            depth, colour, interlace = chunk[8], chunk[9], chunk[12]
        elif tag == b'IDAT':
            idat += chunk
        elif tag == b'IEND':
            break
        i += 12 + ln
    if depth != 8 or interlace != 0 or colour not in (0, 2, 4, 6):
        raise SystemExit(f'{path}: only 8-bit non-interlaced grey/RGB/RGBA is supported '
                         f'(got depth={depth} colour={colour} interlace={interlace})')
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[colour]
    raw = zlib.decompress(idat)
    stride = w * channels
    rows = []
    prior = bytearray(stride)
    off = 0
    for _ in range(h):
        ftype = raw[off]
        line = bytearray(raw[off + 1:off + 1 + stride])
        off += 1 + stride
        if ftype == 1:
            for x in range(channels, stride):
                line[x] = (line[x] + line[x - channels]) & 0xFF
        elif ftype == 2:
            for x in range(stride):
                line[x] = (line[x] + prior[x]) & 0xFF
        elif ftype == 3:
            for x in range(stride):
                left = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((left + prior[x]) >> 1)) & 0xFF
        elif ftype == 4:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                b = prior[x]
                c = prior[x - channels] if x >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 0xFF
        elif ftype != 0:
            raise SystemExit(f'{path}: bad filter {ftype}')
        prior = line
        rows.append(line)

    if channels <= 2:                       # grey (with or without alpha): take byte 0
        grey = [bytes(r[0::channels]) for r in rows]
    else:                                   # RGB(A): green channel
        grey = [bytes(r[1::channels]) for r in rows]
    return grey, w, h


def crop_middle(grey, w, h, cw=480, ch=300):
    """The most detailed 480x300 window of a big screenshot.

    Scaling 14.7 MP into 25 cells shows a dark rectangle whatever the format, and a dark-mode
    terminal would look "all black" even at 1:1. So look at nine windows and pick the one with the
    most distinct grey levels -- that is the one where "is it grey and is it sharp?" can be judged.
    The tables still measure the whole image.
    """
    if w <= cw and h <= ch:
        return grey, w, h
    best, chosen = -1, ((w - cw) // 2, (h - ch) // 2)
    for gy in (0, (h - ch) // 2, h - ch):
        for gx in (0, (w - cw) // 2, w - cw):
            window = [row[gx:gx + cw] for row in grey[gy:gy + ch:16]]
            levels = len(set(b''.join(window)))          # C-speed: distinct bytes in the sample
            if levels > best:
                best, chosen = levels, (gx, gy)
    gx, gy = chosen
    return [row[gx:gx + cw] for row in grey[gy:gy + ch]], cw, ch


def rgb_plane(grey):
    """Grey rows -> RGB rows, 3 bytes per pixel, via slice assignment (no per-pixel loop)."""
    out = []
    for row in grey:
        buf = bytearray(len(row) * 3)
        buf[0::3] = row
        buf[1::3] = row
        buf[2::3] = row
        out.append(bytes(buf))
    return out


# ---------------------------------------------------------------- encoders

def _chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))


def _png(w, h, depth, colour, rows, plte=None):
    out = (b'\x89PNG\r\n\x1a\n' + _chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, depth, colour, 0, 0, 0)))
    if plte:
        out += _chunk(b'PLTE', plte)
    return out + _chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + _chunk(b'IEND', b'')


def png_grey(grey, w, h):
    return _png(w, h, 8, 0, b''.join(b'\x00' + row for row in grey))


def pack_bits(indices, bits):
    """Gather `8//bits` index bytes into one output byte without a Python loop over pixels.

    Each lane is one pixel position within a group; shifting a lane by its bit offset and OR-ing
    the big integers combines them byte by byte, because OR cannot carry between bytes.
    """
    per = 8 // bits
    n = (len(indices) + per - 1) // per
    # every lane pads to n bytes: a short lane would shift every later group by one byte
    lanes = [indices[k::per] + bytes(n - len(indices[k::per])) for k in range(per)]
    acc = 0
    for k, lane in enumerate(lanes):
        acc |= int.from_bytes(lane, 'big') << (bits * (per - 1 - k))
    return acc.to_bytes(n, 'big')


def png_palette(grey, w, h, bits):
    levels = 1 << bits
    table = _index_table(levels)
    plte = b''.join(bytes((v, v, v)) for v in (round(i * 255 / (levels - 1)) for i in range(levels)))
    rows = b''.join(b'\x00' + pack_bits(row.translate(table), bits) for row in grey)
    return _png(w, h, bits, 3, rows, plte)


def rgb_zlib(rgb):
    return zlib.compress(b''.join(rgb), 6)


def rgb565_zlib(rgb):
    out = []
    for row in rgb:
        buf = bytearray(row)
        buf[0::3] = row[0::3].translate(_TR_5)
        buf[1::3] = row[1::3].translate(_TR_6)
        buf[2::3] = row[2::3].translate(_TR_5)
        out.append(bytes(buf))
    return zlib.compress(b''.join(out), 6)


def grey_zlib(grey):
    return zlib.compress(b''.join(grey), 6)


# ---------------------------------------------------------------- per-tile measurement

def tile_count(w, h):
    return ((w + TILE_W - 1) // TILE_W) * ((h + TILE_H - 1) // TILE_H)


def sample_rects(w, h, budget):
    """Every tile when there are few, an even sample when there are many (14.7 MP = 858 tiles)."""
    total = tile_count(w, h)
    step = max(1, -(-total // max(1, budget)))
    rects = []
    i = 0
    for y in range(0, h, TILE_H):
        for x in range(0, w, TILE_W):
            if i % step == 0:
                rects.append((x, y, min(TILE_W, w - x), min(TILE_H, h - y)))
            i += 1
    return rects, total


def per_tile(rows, w, h, enc, budget):
    """Sum of one independent payload per tile, extrapolated from a sample."""
    rects, total = sample_rects(w, h, budget)
    total_bytes = 0
    for x, y, cw, ch in rects:
        tile = [row[x * (len(row) // w):(x + cw) * (len(row) // w)] for row in rows[y:y + ch]]
        total_bytes += len(enc(tile, cw, ch))
    scale = total / len(rects)
    return total_bytes * scale, len(rects), total


# ---------------------------------------------------------------- terminal plumbing

def pane():
    """(cols, rows, cell_w, cell_h). sshd ptys usually report no pixel size; assume 8x16."""
    try:
        buf = array.array('H', [0, 0, 0, 0])
        fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, buf)
    except OSError:
        return 100, 40, 8, 16
    rows, cols, xp, yp = buf[0], buf[1], buf[2], buf[3]
    if cols <= 0 or rows <= 0:
        return 100, 40, 8, 16
    if xp and yp:
        return cols, rows, xp / cols, yp / rows
    return cols, rows, 8, 16


class Reply:
    """Reads the terminal's APC replies (`ESC_Gi=..;OK ESC\\`) without losing them to the shell."""

    def __init__(self):
        self.fd = sys.stdin.fileno()
        self.raw = False
        try:
            self.saved = termios.tcgetattr(self.fd)
            tty.setraw(self.fd)
            self.raw = True
        except termios.error:
            pass

    def expect(self, timeout=0.4):
        if not self.raw:
            return '(no reply)'
        out = b''
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if not r:
                continue
            out += os.read(self.fd, 4096)
            if out.endswith(b'\x1b\\'):
                break
        return out.decode('latin1').strip().replace('\x1b', '\\e') or '(no reply)'

    def close(self):
        if self.raw:
            termios.tcsetattr(self.fd, termios.TCSADRAIN, self.saved)


def transmit(kind, payload, cells_w, cells_h, ident, dims=None):
    b64 = base64.b64encode(payload).decode()
    first = True
    for i in range(0, len(b64), CHUNK):
        part = b64[i:i + CHUNK]
        more = 0 if i + CHUNK >= len(b64) else 1
        if first:
            ctl = f"\033_Gi={ident},a=T,q=1,f={kind},c={cells_w},r={cells_h},C=1,m={more}"
            if dims:
                ctl += f",s={dims[0]},v={dims[1]},o=z"
            sys.stdout.write(ctl + ';' + part + '\033\\')
            first = False
        else:
            sys.stdout.write(f"\033_Gm={more};{part}\033\\")
    sys.stdout.flush()
    return len(b64)


# ---------------------------------------------------------------- main

def main():
    argv = sys.argv[1:]
    quiet = '--no-images' in argv or '--quiet' in argv     # --quiet kept as the old spelling
    budget = int(argv[argv.index('--tiles') + 1]) if '--tiles' in argv else 300
    started = time.time()

    global W, H
    image = None
    if '--image' in argv:
        path = argv[argv.index('--image') + 1]
        grey, W, H = load_png(path)
        image = os.path.basename(path)
        view, VW, VH = crop_middle(grey, W, H)
        sys.stderr.write(f'decoded {image} {W}x{H} in {time.time() - started:.1f}s\n')
    else:
        grey = card()
        view, VW, VH = grey, W, H

    rgb = rgb_plane(grey)
    variants = [
        ('A', 'f=24 + o=z', 'rgb', lambda t, w, h: rgb_zlib(t)),
        ('B', 'f=100 grey 8', 'grey', png_grey),
        ('C', 'f=100 pal 1', 'pal1', lambda t, w, h: png_palette(t, w, h, 1)),
        ('D', 'f=100 pal 4', 'pal4', lambda t, w, h: png_palette(t, w, h, 4)),
    ]
    planes = {'rgb': rgb, 'grey': grey}
    whole = {name: len(enc(planes[name if name in planes else 'grey'], W, H)) for _, _, name, enc in variants}
    whole['rgb'] = len(rgb_zlib(rgb))
    # the invariant the terminal enforces: after inflate, o=z must be exactly s*v*bytesPerPixel
    assert len(zlib.decompress(rgb_zlib(rgb))) == W * H * 3, 'f=24 + o=z payload size is wrong'

    tiles = {}
    for _, _, name, enc in variants:
        plane = rgb if name == 'rgb' else grey
        tiles[name], sampled, total = per_tile(plane, W, H, enc, budget)
    q565, _, _ = per_tile(rgb, W, H, lambda t, w, h: rgb565_zlib(t), budget)
    grey_z, _, _ = per_tile(grey, W, H, lambda t, w, h: grey_zlib(t), budget)

    lines = ['', f'{"screenshot " + image if image else "synthetic card"}, whole image {W}x{H}'
                 f' (x1.33 = what the pty carries):']
    for letter, label, name, _ in variants:
        size = whole[name]
        lines.append(f'  {letter}  {label:14s} {size:8d} B  x1.33 = {int(size * 4 / 3):8d} B'
                     f'   {whole["rgb"] / size:5.2f}x vs A')
    lines.append('')
    lines.append(f'per {TILE_W}x{TILE_H} tile, {total} tiles'
                 f'{" (sampled " + str(sampled) + ", extrapolated)" if sampled < total else ""}:')
    for letter, label, name, _ in variants:
        size = tiles[name]
        lines.append(f'  {letter}  {label:14s} {size:8.0f} B   {tiles["rgb"] / size:5.2f}x vs A')
    lines.append(f'  -  rgb + 5-6-5    {q565:8.0f} B   {tiles["rgb"] / q565:5.2f}x vs A   (shipped #59;'
                 f' only for incompressible tiles, and it ties or loses on flat content)')
    lines.append(f'  E  grey8 + o=z    {grey_z:8.0f} B   {tiles["rgb"] / grey_z:5.2f}x vs A   (NOT'
                 f' sendable: needs a new f=; B is the same pixels plus PNG framing)')
    if image is None:
        lines.append('')
        lines.append('synthetic card: mostly flat, so packing looks weak here. Measure your own'
                     ' screen with --image shot.png.')
    lines.append('')
    lines.append(f'measured in {time.time() - started:.1f}s')
    report = '\n'.join(lines)

    cols, rows, cw, ch = pane()
    if quiet or cols < 60 or rows < 20:
        print(report)
        print('(nothing drawn: --no-images)' if quiet else f'(pane {cols}x{rows} is too small for the cards)')
        return

    # the synthetic cards differ only by their letter, so each panel is visibly its own format;
    # with --image all four show the same picture, which is the comparison we actually want
    payloads = {}
    for letter, _, name, enc in variants:
        content = list(view)
        if image is None:
            stamp(content, letter, 20, VH - 90)
        plane = rgb_plane(content) if name == 'rgb' else content
        payloads[name] = enc(plane, VW, VH)

    # Fit the 2x2 card grid to the pane: width *and* height. A portrait screenshot (2880x5120)
    # used to size the cards by width alone, which needs 118 rows and silently drew nothing.
    table_rows = len(lines) + 1
    c_max = (cols - 6) // 2
    r_max = max(2, (rows - 4 - table_rows - 1 - 4) // 2)      # two card rows, 2 non-image rows each
    c = c_max
    r = max(1, int(c * cw * VH / VW / ch))
    if r > r_max:                                             # too tall: shrink to the height budget
        r = r_max
        c = max(1, int(r * ch * VW / (VH * cw)))
    if c < 12 or r < 5:
        print(report)
        print(f'(pane {cols}x{rows}: the cards would be {c}x{r} cells, too small to judge; '
              f'use --no-images or a bigger pane)')
        return

    gap = 2
    x0, x1 = 1, 1 + c + gap
    y0, y1 = 4, 4 + r + 2
    if x1 + c - 1 > cols or y1 + r + 1 > rows - table_rows:
        print(report)
        print(f'(pane {cols}x{rows}: no room for {c}x{r} cards plus the table)')
        return

    reply = Reply()
    try:
        sys.stdout.write('\033[2J\033[H')
        sys.stdout.write('gray_probe: does this terminal take grey / paletted PNG (f=100)?\n')
        sys.stdout.write('all four cards must look the same; B/C/D must be grey, not tinted\n')
        sys.stdout.write('A = f=24 + o=z   B = f=100 8-bit grey   C = f=100 1-bit   D = f=100 4-bit\n')
        if image:
            sys.stdout.write(f'cards show a {VW}x{VH} crop of {image}; the tables measure all {W}x{H}\n')
        spots = {'A': (y0, x0), 'B': (y0, x1), 'C': (y1, x0), 'D': (y1, x1)}
        for i, (letter, label, name, _) in enumerate(variants):
            row, col = spots[letter]
            sys.stdout.write(f'\033[{row};{col}H\033[0m{letter}  {label:14s}')
            sys.stdout.write(f'\033[{row + 1};{col}H')
            dims = (VW, VH) if name == 'rgb' else None
            transmit(24 if name == 'rgb' else 100, payloads[name], c, r,
                     900 + i, dims=dims)
            status = reply.expect()
            note = 'ok' if 'no reply' in status else status[:c - 2]
            sys.stdout.write(f'\033[{row + r + 1};{col}H\033[0m\033[2m{note}')
            sys.stdout.flush()

        top = min(y1 + r + 2, rows - len(lines) - 1)
        for i, line in enumerate(report.split('\n')):
            if top + i < rows:
                sys.stdout.write(f'\033[{top + i};1H\033[0m{line[:cols - 1]}')
        sys.stdout.write(f'\033[{rows};1H\033[0mdeleting the images in 15 s (Ctrl-C is fine)')
        sys.stdout.flush()
        time.sleep(15)
    finally:
        sys.stdout.write('\033_Ga=d,d=A,q=2\033\\\033[0m\n')
        sys.stdout.flush()
        reply.close()


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:                 # `| head` is a normal way to read the table
        os._exit(0)
    except KeyboardInterrupt:
        pass
