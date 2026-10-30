"""Turn a kitty-graphics escape stream back into the pixels a terminal would show.

`krd` writes and never reads back, so "did the picture land?" is answered by looking at the
glass - which a headless agent cannot do. This module answers it from the bytes: feed what the
writer emitted, get back the frames it drew.

Limits, stated up front, because a decoder that oversells itself is worse than none:

* Geometry belongs to the terminal (`c`/`r` cells, `U=1` placeholder cells), so an image is
  fitted into its cell rectangle and resampled **nearest-neighbour**. The terminal may use a
  better filter; at krd's 1:1 pixel:cell geometry the resample branch never runs.
* `f=32` keeps its alpha in `Image.pixels` and is composited **source-over** onto the canvas,
  which starts black - the terminal's blend, not a silent alpha drop.
* `f=100` (PNG) is **not** decoded: `png.py` stays a writer, and krd emits only f=24/f=32
  (Tile.swift:173). A PNG payload raises `UnsupportedError`, which the decoder records in
  `anomalies` and survives - one odd picture must not blind the agent.
* Text is not rendered; a banner line moves the cursor and paints nothing.

The diacritic table is `Render.swift:456` (`placeholderDiacritics`) verbatim; `test_vt.py`
re-reads that line and fails if the two ever drift apart.
"""

import base64
import codecs
import os
import sys
import zlib

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:  # agents load these by path; the sibling import needs the directory
    sys.path.append(_HERE)
import png  # noqa: E402

PLACEHOLDER = 0x10EEEE
# kitty's rowcolumn-diacritics.txt: index = row/column number. Sources/krdcore/Render.swift:456.
DIACRITICS = (
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B, 0x034C,
    0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
    0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
    0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
    0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
    0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
    0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2, 0x06E4, 0x06E7, 0x06E8, 0x06EB,
    0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
    0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3,
    0x0816, 0x0817, 0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
    0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951, 0x0953, 0x0954,
    0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
    0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71,
    0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
    0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
    0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
    0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1, 0x20D4, 0x20D5, 0x20D6, 0x20D7,
    0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
    0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE,
    0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
    0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1,
    0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5,
)
_DIA = {cp: i for i, cp in enumerate(DIACRITICS)}


class UnsupportedError(Exception):
    """An image the decoder cannot turn into pixels (see the module docstring for which)."""


class Image:
    """One transmitted picture; `pixels` is `w * h * channels` packed bytes."""

    __slots__ = ("w", "h", "channels", "pixels")

    def __init__(self, w, h, channels, pixels):
        self.w, self.h, self.channels, self.pixels = w, h, channels, pixels


class Placement:
    """One `a=p`, 1-based cells. For `unicode_placeholder` the rect is the grid's, settled
    when the frame closes - a terminal paints the image in the cells, not at the cursor."""

    __slots__ = ("image_id", "placement_id", "col", "row", "cols", "rows",
                 "unicode_placeholder", "z", "_declared")

    def __init__(self, image_id, placement_id, col, row, cols, rows, unicode_placeholder, z):
        self.image_id, self.placement_id = image_id, placement_id
        self.col, self.row, self.cols, self.rows = col, row, cols, rows
        self.unicode_placeholder, self.z = unicode_placeholder, z
        self._declared = (cols, rows)      # what the command asked for; the grid may clip it

    def __repr__(self):
        return (f"Placement(img={self.image_id} p={self.placement_id} {self.cols}x{self.rows}"
                f" @ {self.row},{self.col}{' U' if self.unicode_placeholder else ''})")


class Frame:
    """What the terminal held at one `ESC[?2026l`; `rgb` is `width * height * 3`, black-backed."""

    __slots__ = ("width", "height", "rgb", "images", "cells", "placements")

    def __init__(self, width, height, rgb, images, cells, placements):
        self.width, self.height, self.rgb = width, height, rgb
        self.images, self.cells, self.placements = images, cells, placements

    def probe(self, x, y):
        o = (y * self.width + x) * 3
        return (self.rgb[o], self.rgb[o + 1], self.rgb[o + 2])

    def png_bytes(self):
        return png.write_png_bytes(self.width, self.height, self.rgb)

    def __repr__(self):
        return (f"Frame({self.width}x{self.height} images={self.images}"
                f" placements={self.placements} cells={self.cells})")


def _num(value):
    try:
        return int(value)
    except ValueError:
        return 0


def _b64(chunks):
    data = b"".join(chunks)
    data += b"=" * (-len(data) % 4)
    try:
        return base64.b64decode(data, validate=False)
    except Exception:
        # Some producers use the URL-safe alphabet; kitty accepts both, so we do too.
        return base64.b64decode(data.translate(bytes.maketrans(b"-_", b"+/")), validate=False)


def _image_from(w, h, f, raw):
    if f not in (24, 32):
        raise UnsupportedError(f"f={f} is not raw RGB/RGBA (f=24/f=32)")
    channels = 3 if f == 24 else 4
    want = w * h * channels
    if len(raw) < want:
        raise UnsupportedError(f"f={f} s={w} v={h} wants {want} B, got {len(raw)}")
    return Image(w, h, channels, bytes(raw[:want]))


class Decoder:
    """Incremental decoder for one terminal's OUTPUT stream.

    `cell_w`/`cell_h` are only consulted when a placement names no `c`/`r` (krd always does).
    `cols`/`rows` pin the pane: with them a frame is always `cols*cell_w` by `rows*cell_h`,
    even when the last columns were not repainted - that is what the terminal shows, and it
    keeps frame sizes stable across a stream instead of shrinking to the dirtiest tile.
    """

    def __init__(self, cell_w=17, cell_h=33, cols=None, rows=None):
        self.cell_w, self.cell_h, self.cols, self.rows = cell_w, cell_h, cols, rows
        self.anomalies = []          # streams disagreeing with themselves; frames still decode
        self._buf = bytearray()
        self._utf8 = codecs.getincrementaldecoder("utf-8")("replace")
        self._row = self._col = 1
        self._fg = (255, 255, 255)
        self._chunk = None           # the `a=t` set still collecting chunks
        self._images, self._placements, self._frames = {}, [], []
        self._grid = {}              # image id -> [[cell row, cell col, img row, img col], ...]
        self._last_ph = None
        self._canvas, self._cw, self._ch = bytearray(), 0, 0
        self._extent_x = self._extent_y = 0
        self._frame_placements, self._frame_cells = [], 0
        self._frame_touched = False
        self._missing = set()
        self._auto_id = 1 << 24      # for `a=T` without `i=`: the terminal invents one, so do we

    def feed(self, data):
        if isinstance(data, str):
            data = data.encode("utf-8", "surrogateescape")
        self._buf += data
        self._drain()

    def frames(self):
        return list(self._frames)

    def images(self):
        return dict(self._images)

    def placements(self):
        return list(self._placements)   # the whole history, in stream order

    # -- scanning --------------------------------------------------------------

    def _drain(self):
        buf, i = self._buf, 0
        while i < len(buf):
            if buf[i] == 0x1B:
                nxt = self._escape(buf, i)
                if nxt is None:
                    break
                i = nxt
                continue
            end = buf.find(b"\x1b", i)
            if end >= 0:                      # text runs up to the next escape
                self._text(self._utf8.decode(bytes(buf[i:end]), True))
                i = end
                continue
            self._text(self._utf8.decode(bytes(buf[i:]), False))
            pending = len(self._utf8.getstate()[0])
            i = len(buf) - pending
            if pending:                       # half a sequence: it comes back with the next feed
                self._utf8.reset()
                break
        self._buf = buf[i:]

    def _escape(self, buf, i):
        if i + 1 >= len(buf):
            return None
        lead = buf[i + 1]
        if lead == 0x5F:                      # APC: ESC _ <kitty body> ESC \
            end = buf.find(b"\x1b\\", i + 2)
            if end < 0:
                return None
            self._apc(bytes(buf[i + 2:end]))
            self._last_ph = None
            return end + 2
        if lead == 0x5B:                      # CSI: ESC [ params final
            j = i + 2
            while j < len(buf) and 0x20 <= buf[j] <= 0x3F:
                j += 1
            if j >= len(buf):
                return None
            self._csi(bytes(buf[i + 2:j]), buf[j])
            return j + 1
        if lead == 0x5D:                      # OSC: not emitted by krd, must not desync
            ends = [x for x in ((buf.find(b"\x1b\\", i + 2), 2), (buf.find(b"\x07", i + 2), 1))
                    if x[0] >= 0]
            if not ends:
                return None
            end, width = min(ends)
            return end + width
        return i + 2                          # bare ST or another two-byte escape: nothing to do

    def _csi(self, params, final):
        if final in (0x48, 0x66):                          # H / f: CUP, both default to 1
            first, _, second = params.partition(b";")
            self._row, self._col = _num(first) or 1, _num(second) or 1
        elif final == 0x47:                                # G: CHA
            self._col = _num(params) or 1
        elif final == 0x64:                                # d: VPA
            self._row = _num(params) or 1
        elif final == 0x4A and params in (b"2", b"3"):      # J: ED, krd clears with 2
            self._canvas, self._cw, self._ch = bytearray(), 0, 0
            self._extent_x = self._extent_y = 0
        elif final == 0x6D:                                # m: SGR, the placeholder colour
            parts = params.split(b";")
            if len(parts) >= 5 and parts[0] == b"38" and parts[1] == b"2":
                self._fg = (_num(parts[2]) & 0xFF, _num(parts[3]) & 0xFF, _num(parts[4]) & 0xFF)
            elif params in (b"", b"0", b"39"):
                self._fg = (255, 255, 255)
        elif final == 0x6C and params == b"?2026":         # DEC 2026: the frame is committed
            self._close_frame()
        self._last_ph = None

    def _text(self, text):
        for ch in text:
            cp = ord(ch)
            if cp in _DIA:
                self._mark(cp)               # the diacritic belongs to the cell before it
                continue
            self._last_ph = None
            if cp == PLACEHOLDER:
                self._placeholder()
            elif cp == 0x0A:
                self._row, self._col = self._row + 1, 1
            elif cp == 0x0D:
                self._col = 1
            elif cp >= 0x20:
                self._col += 1               # printable text moves the cursor, paints nothing

    # -- kitty APC -------------------------------------------------------------

    def _apc(self, body):
        head, _, payload = body.partition(b";")
        if head[:1] == b"G":
            head = head[1:]
        kv = {}
        for field in head.split(b","):
            key, _, value = field.partition(b"=")
            if key:
                kv[key.decode("latin1")] = value.decode("latin1")
        if not {"a", "i", "f"} & set(kv) and self._chunk is not None:
            self._transmit(kv, payload, fresh=False)      # continuation: only `m` and base64
            return
        action = kv.get("a", "t")
        if action in ("t", "T"):
            self._transmit(kv, payload, fresh=True)
        elif action == "p":
            self._place(kv)
        # `a=d` (delete) frees the *terminal's* copy after the pixels are already on the glass,
        # and every krd session ends with `a=d,d=a` (Render.swift:200, :224): honouring it would
        # empty images()/placements() exactly when an agent comes asking. krd retransmits an id
        # before placing it again, so keeping the store cannot draw anything stale.
        # `a=q`/`a=f`/`a=c` carry no pixels either.

    def _transmit(self, kv, payload, fresh):
        if fresh:
            iid = _num(kv.get("i", "0"))
            if not iid:                       # a=T without i=: the terminal invents an id
                self._auto_id += 1
                iid = self._auto_id
            self._chunk = {"i": iid, "f": _num(kv.get("f", "32")), "s": _num(kv.get("s", "0")),
                           "v": _num(kv.get("v", "0")), "z": kv.get("o") == "z",
                           "draw": kv.get("a") == "T", "parts": [payload],
                           "at": {k: kv[k] for k in ("c", "r", "U") if k in kv}}
        else:
            self._chunk["parts"].append(payload)
        if kv.get("m", "0") == "1":
            return
        chunk, self._chunk = self._chunk, None
        raw = _b64(chunk["parts"])
        if chunk["z"]:
            try:
                raw = zlib.decompress(raw)
            except zlib.error as exc:
                self.anomalies.append(f"image {chunk['i']}: o=z payload: {exc}")
                return
        try:
            self._images[chunk["i"]] = _image_from(chunk["s"], chunk["v"], chunk["f"], raw)
        except UnsupportedError as exc:
            self.anomalies.append(f"image {chunk['i']}: {exc}")
            return
        if chunk["draw"]:                     # a=T draws as it transmits (Render.swift:662)
            self._place(dict(chunk["at"], i=str(chunk["i"])))

    def _place(self, kv):
        iid = _num(kv.get("i", "0"))
        cols = _num(kv["c"]) if "c" in kv else None
        rows = _num(kv["r"]) if "r" in kv else None
        if cols is None or rows is None:     # no c/r: the image's pixel size decides
            img = self._images.get(iid)
            cols = cols or -(-(img.w if img else self.cell_w) // self.cell_w)
            rows = rows or -(-(img.h if img else self.cell_h) // self.cell_h)
        p = Placement(iid, _num(kv.get("p", str(iid))), self._col, self._row,
                      max(1, cols), max(1, rows), kv.get("U") == "1", _num(kv.get("z", "0")))
        self._placements.append(p)
        self._frame_placements.append(p)
        self._frame_touched = True
        if kv.get("C") != "1":               # C=1 keeps the cursor, so the next anchor holds
            self._col += p.cols
            self._row += p.rows - 1

    # -- unicode placeholders --------------------------------------------------

    def _placeholder(self):
        iid = (self._fg[0] << 16) | (self._fg[1] << 8) | self._fg[2]
        cells = self._grid.setdefault(iid, [])
        cells.append([self._row, self._col, None, None])
        self._last_ph = cells[-1]
        self._frame_cells += 1
        self._frame_touched = True
        self._col += 1

    def _mark(self, cp):
        rec = self._last_ph
        if rec is None:
            return
        index = _DIA[cp]
        if rec[2] is None:
            rec[2] = index                    # first diacritic: the row of the image
        elif rec[3] is None:
            rec[3] = index                    # second: the column

    def _labelled(self, cells):
        """Fill in the cells that carry no diacritic of their own.

        kitty's rule: a bare placeholder inherits the cell to its left, column + 1; a cell with
        only a row diacritic is column 0 of that row. krd leans on the first (Render.swift:503
        writes one diacritic per line), and reading the labels back turns "the cells are
        somewhere" into "each cell names the slice of the image that belongs in it".
        """
        out, prev = [], None
        for cell_row, cell_col, img_row, img_col in cells:
            if img_row is None:
                img_row, img_col = (prev[2], prev[3] + 1) if prev else (0, 0)
            elif img_col is None:
                img_col = 0
            prev = (cell_row, cell_col, img_row, img_col)
            out.append(prev)
        return out

    def _resolve_placements(self, pending, grid):
        """Settle every `U=1` rect, and invent one for a grid nobody placed.

        A `U=1` placement carries no position: the image goes where the placeholder cells are,
        which is the only geometry a terminal uses (Render.swift:488 emits exactly that pair).
        krd also clips the grid at the pane's last row (:497), so a grid *smaller* than the
        declared `c`/`r` is a normal edge case - a larger one is a bug in whoever wrote the
        stream and lands in `anomalies`, not in an assert that would kill the decode.
        """
        seen = set()
        for p in pending:
            seen.add(p.image_id)              # a placed image is drawn once, grid or not
            cells = grid.get(p.image_id)
            if not p.unicode_placeholder or not cells:
                continue                      # no cells: the cursor-derived rect is all we have
            rows, cols = [c[0] for c in cells], [c[1] for c in cells]
            p.row, p.col = min(rows), min(cols)
            p.rows, p.cols = max(rows) - p.row + 1, max(cols) - p.col + 1
            if p.cols > p._declared[0] or p.rows > p._declared[1]:
                self.anomalies.append(f"placement {p.placement_id}: grid is {p.cols}x{p.rows}"
                                      f" at {p.row},{p.col} but asked for"
                                      f" {p._declared[0]}x{p._declared[1]}")
            for cell_row, cell_col, img_row, img_col in self._labelled(cells):
                if (img_row, img_col) != (cell_row - p.row, cell_col - p.col):
                    self.anomalies.append(f"placement {p.placement_id}: cell {cell_row},{cell_col}"
                                          f" is labelled image row={img_row} col={img_col}")
                    break
        for iid, cells in grid.items():
            if iid not in seen:
                rows, cols = [c[0] for c in cells], [c[1] for c in cells]
                p = Placement(iid, 0, min(cols), min(rows), max(cols) - min(cols) + 1,
                              max(rows) - min(rows) + 1, True, 0)
                self._placements.append(p)
                pending.append(p)

    # -- raster ----------------------------------------------------------------

    def _ensure_canvas(self, w, h):
        if w <= self._cw and h <= self._ch:
            return
        nw, nh = max(w, self._cw), max(h, self._ch)
        grown = bytearray(nw * nh * 3)
        for y in range(self._ch):
            grown[y * nw * 3:(y * nw + self._cw) * 3] = self._canvas[y * self._cw * 3:(y + 1) * self._cw * 3]
        self._canvas, self._cw, self._ch = grown, nw, nh

    def _blit(self, img, x0, y0, rw, rh):
        iw, ih, ch, src = img.w, img.h, img.channels, img.pixels
        cv, cw = self._canvas, self._cw
        exact = iw == rw and ih == rh
        xmap = None if exact else [x * iw // rw for x in range(rw)]
        for yy in range(rh):
            srow = (yy if exact else yy * ih // rh) * iw * ch
            drow = ((y0 + yy) * cw + x0) * 3
            if exact and ch == 3:
                cv[drow:drow + rw * 3] = src[srow:srow + rw * 3]   # the 1:1 path krd takes
                continue
            for xx in range(rw):
                s = srow + (xx if exact else xmap[xx]) * ch
                d = drow + xx * 3
                if ch == 3:
                    cv[d], cv[d + 1], cv[d + 2] = src[s], src[s + 1], src[s + 2]
                    continue
                a = src[s + 3]
                if a == 255:
                    cv[d], cv[d + 1], cv[d + 2] = src[s], src[s + 1], src[s + 2]
                elif a:
                    inv = 255 - a
                    cv[d] = (src[s] * a + cv[d] * inv + 127) // 255
                    cv[d + 1] = (src[s + 1] * a + cv[d + 1] * inv + 127) // 255
                    cv[d + 2] = (src[s + 2] * a + cv[d + 2] * inv + 127) // 255

    def _draw(self, p):
        img = self._images.get(p.image_id)
        if img is None:
            if p.image_id not in self._missing:
                self._missing.add(p.image_id)
                self.anomalies.append(f"placement {p.placement_id}: image {p.image_id}"
                                      " was never transmitted")
            return False
        x0, y0 = (p.col - 1) * self.cell_w, (p.row - 1) * self.cell_h
        rw, rh = p.cols * self.cell_w, p.rows * self.cell_h
        if rw <= 0 or rh <= 0 or p.col < 1 or p.row < 1:
            return False
        self._ensure_canvas(x0 + rw, y0 + rh)
        self._blit(img, x0, y0, rw, rh)
        self._extent_x, self._extent_y = max(self._extent_x, x0 + rw), max(self._extent_y, y0 + rh)
        return True

    # -- frames ----------------------------------------------------------------

    def _close_frame(self):
        cells, self._frame_cells = self._frame_cells, 0
        pending, self._frame_placements = self._frame_placements, []
        touched, self._frame_touched = self._frame_touched, False
        grid, self._grid = self._grid, {}
        if not touched:                      # a sync block that drew nothing is not a frame
            return
        self._resolve_placements(pending, grid)
        drawn = 0
        for p in sorted(pending, key=lambda q: q.z):   # stable sort: ties keep stream order
            if self._draw(p):
                drawn += 1
        w, h = self._extent_x, self._extent_y
        if self.cols:
            w = max(w, self.cols * self.cell_w)
        if self.rows:
            h = max(h, self.rows * self.cell_h)
        self._ensure_canvas(w, h)            # cw == w from here: the extents are what grew it
        self._frames.append(Frame(w, h, bytes(self._canvas[:w * h * 3]), drawn, cells, len(pending)))
