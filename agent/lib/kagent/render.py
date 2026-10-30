"""Seeing what krd draws, with no terminal and no screen.

Two halves of the product need two different oracles:

* the **escape stream** — run the binary under a pty, capture exactly the bytes it writes, and decode
  kitty-graphics APCs back into pixels. That is the only way to check "the picture fills its box"
  on a machine whose screen is locked, and it catches the class of bug a text capture cannot: a tile
  placed at the wrong rect still occupies the right cells.
* the **text layer** — the placeholder grid (`U+10EEEE` cells) that survives any text capture, which
  says where the pictures were *supposed* to go and costs nothing.

`render` produces both from one run, so a claim like "the card is 54x20 cells centred at 45..99" is
checked against the picture geometry and the cell geometry at the same time.
"""

import fcntl
import json
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

from .core import KagentError, REPO

sys.path.insert(0, str(REPO / "agent" / "lib"))
import vt as vtd  # noqa: E402  (the decoder lives beside this package, not inside it)


def parse_geometry(text, default=None):
    if not text:
        return default
    left, _, right = text.partition("x")
    return int(left), int(right)


class TerminalAnswers:
    """A pty that answers like the terminal krd is developed against.

    krd asks two questions before it chooses a transport, and the answers change what it draws:
    a `U=1` placeholder probe ("can you fit a picture into cells") and a device-status report. A
    bare pty answers neither, so krd falls back to pixel-sized pictures — a real code path, but not
    the one Rex takes, and measuring the wrong path is how "it works in the harness" starts lying.

    The replies are the ones Rex sends, including the detail that cost this repo a day: kitty echoes
    the request's parameters, so a `U=1` placement answers `i=31,p=1;OK` and not `i=31;OK`.
    """

    def __init__(self, fd, cell=(17, 33), name="rex"):
        self.fd = fd
        self.cell = cell
        self.name = name
        self.seen = bytearray()
        self.answered = {"u1": 0, "dsr": 0, "cellsize": 0, "query": 0}

    def _write(self, data):
        try:
            os.write(self.fd, data)
        except OSError:
            pass

    def feed(self, data):
        if self.name == "none":
            return
        self.seen.extend(data)
        if len(self.seen) > 65536:
            del self.seen[:32768]
        if b"\x1b[5n" in self.seen:
            self.seen = self.seen.replace(b"\x1b[5n", b"", 1)
            self._write(b"\x1b[0n")
            self.answered["dsr"] += 1
        if b"\x1b[16t" in self.seen:
            self.seen = self.seen.replace(b"\x1b[16t", b"", 1)
            self._write(("\x1b[6;%d;%dt" % (self.cell[1], self.cell[0])).encode())
            self.answered["cellsize"] += 1
        # One placement probe at a time; the bytes are consumed so a later frame is answered again.
        marker = b",U=1"
        index = self.seen.find(marker)
        if index >= 0:
            start = self.seen.rfind(b"\x1b_G", 0, index)
            end = self.seen.find(b"\x1b\\", index)
            if start >= 0 and end >= 0:
                body = bytes(self.seen[start:end])
                del self.seen[start:end + 2]
                ident = b"i=31"
                for part in body.split(b","):
                    if part.startswith(b"i="):
                        ident = part.split(b";")[0]
                        break
                placement = b"p=1" if b"p=" in body else b""
                reply = b"\x1b_G" + ident + (b"," + placement if placement else b"") + b";OK\x1b\\"
                self._write(reply)
                self.answered["u1"] += 1


def resize(fd, cols, rows, cell=None):
    """Set the pty's size and let the kernel deliver SIGWINCH.

    Resizing is where stale geometry shows up: the layout is recomputed, but the pictures already
    on screen were placed for the old rectangle. Driving it here is the only way to check the
    resize path without a person dragging a window edge.
    """
    width, height = cell or (0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ,
                struct.pack("HHHH", rows, cols, width * cols, height * rows))


def run_under_pty(argv, cols=146, rows=73, seconds=10.0, cell=None, env=None, cwd=None,
                  on_chunk=None, terminal="rex", resizes=None):
    """Run `argv` on a pty of exactly `cols`x`rows`, and collect every byte it writes.

    A pty is not a convenience here: krd takes its geometry from `TIOCGWINSZ` and its behaviour from
    whether the other end answers queries, so a pipe measures a different program.
    """
    master, slave = pty.openpty()
    width, height = cell or (0, 0)
    fcntl.ioctl(slave, termios.TIOCSWINSZ,
                struct.pack("HHHH", rows, cols, width * cols, height * rows))
    child_env = dict(os.environ)
    child_env.update(env or {})
    child_env.pop("KAGENT_RUN", None)
    # `start_new_session=True` is not enough: it makes a new session but never makes the pty the
    # child's *controlling* terminal, so the kernel has no foreground process group to send SIGWINCH
    # to. The symptom is a resize that changes `stty size` and delivers nothing — krd keeps drawing
    # the old layout and it looks exactly like a product bug. TIOCSCTTY is the missing call.
    def child_setup():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                               preexec_fn=child_setup, env=child_env, cwd=cwd or str(REPO),
                               close_fds=True)
    # The slave stays open in the parent: on macOS TIOCSWINSZ on the master does not always reach
    # the child's terminal, and a resize that silently does nothing is worse than no resize at all.
    answers = TerminalAnswers(master, cell=(cell or (17, 33)), name=terminal)
    # (at_seconds, cols, rows): a resize in the middle of the run, the way a person drags a window.
    pending = sorted(resizes or [])
    started = time.time()
    chunks = []
    status = None
    while True:
        remaining = seconds - (time.time() - started)
        if remaining <= 0:
            break
        while pending and time.time() - started >= pending[0][0]:
            _, new_cols, new_rows = pending.pop(0)
            resize(slave, new_cols, new_rows, cell)
            pass
        ready, _, _ = select.select([master], [], [], min(0.2, max(0.01, remaining)))
        if ready:
            try:
                data = os.read(master, 1 << 16)
            except OSError:
                data = b""
            if not data:
                break
            chunks.append(data)
            answers.feed(data)
            if on_chunk:
                on_chunk(data)
        if process.poll() is not None and not ready:
            # Drain what is left, then stop: a finished command is done even if `seconds` remains.
            while True:
                ready, _, _ = select.select([master], [], [], 0.1)
                if not ready:
                    break
                try:
                    data = os.read(master, 1 << 16)
                except OSError:
                    data = b""
                if not data:
                    break
                chunks.append(data)
            status = process.returncode
            break
    if process.poll() is None:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            process.wait(timeout=5)
        except Exception:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except Exception:
                pass
    status = process.returncode if process.returncode is not None else status
    os.close(master)
    os.close(slave)
    return b"".join(chunks), status, time.time() - started, answers.answered


def decode(stream, cols, rows, cell):
    decoder = vtd.Decoder(cell_w=cell[0], cell_h=cell[1], cols=cols, rows=rows)
    decoder.feed(stream)
    return decoder


def text_layer(stream, cols):
    """The buffer a text capture would show, and the placeholder runs in it."""
    import re
    clean = stream.decode("utf-8", "replace")
    clean = re.sub(r"\x1b_G.*?\x1b\\", "", clean, flags=re.S)
    clean = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", clean)
    lines = clean.split("\n")
    return lines


def placeholder_runs(stream, cols, rows):
    """Per row: how many placeholder cells and which columns they cover.

    This is the geometry check that needs no pixels at all: a picture that does not equal its box
    shows up as a shorter run, an off-centre start, or a gap.
    """
    import re
    placeholder = chr(0x10EEEE)
    # The grid is written as CUP + fg colour + cells, so rebuild the screen from the CUPs rather
    # than trusting newlines: krd positions every row explicitly.
    text = stream.decode("utf-8", "replace")
    screen = {}
    row, col = 1, 1
    i = 0
    while i < len(text):
        if text.startswith("\x1b[", i):
            match = re.match(r"\x1b\[([0-9;]*)([A-Za-z])", text[i:])
            if not match:
                i += 1
                continue
            params, final = match.group(1), match.group(2)
            if final == "H":
                parts = [p for p in params.split(";") if p.isdigit()]
                row = int(parts[0]) if parts else 1
                col = int(parts[1]) if len(parts) > 1 else 1
            elif final == "J":
                screen.clear()
            i += len(match.group(0))
            continue
        if text.startswith("\x1b", i):
            if text.startswith("\x1b_G", i):
                end = text.find("\x1b\\", i)
                i = len(text) if end < 0 else end + 2
                continue
            i += 1
            continue
        char = text[i]
        if char == "\n":
            row += 1
            col = 1
        elif char == "\r":
            col = 1
        else:
            screen.setdefault(row, {})[col] = char
            col += 1
        i += 1

    runs = []
    for r in range(1, rows + 1):
        cells = sorted(c for c, ch in screen.get(r, {}).items()
                       if ch == placeholder or 0x0300 <= ord(ch) <= 0x036F)
        if not cells:
            continue
        # The per-row diacritic sits in a cell of its own, splitting one picture into two runs.
        # A gap of one cell is that artefact, not a hole in the picture, so runs are merged before
        # they are reported — otherwise every card looks like two.
        start = previous = cells[0]
        for cell in cells[1:]:
            if cell > previous + 2:
                runs.append((r, start, previous))
                start = cell
            previous = cell
        runs.append((r, start, previous))
    return runs


def summary(runs):
    """Collapse per-row runs into rectangles: a picture is a contiguous block of rows."""
    if not runs:
        return []
    rects = []
    current = {"row0": runs[0][0], "row1": runs[0][0], "col0": runs[0][1], "col1": runs[0][2],
               "cells": 0}
    for row, start, end in runs:
        same_shape = start == current["col0"] and end == current["col1"]
        if row == current["row1"] + 1 and same_shape:
            current["row1"] = row
            current["cells"] += end - start + 1
        else:
            rects.append(current)
            current = {"row0": row, "row1": row, "col0": start, "col1": end, "cells": end - start + 1}
    rects.append(current)
    out = sorted(rects, key=lambda r: (r["row0"], r["col0"]))
    for rect in out:
        rect["rows"] = rect["row1"] - rect["row0"] + 1
        rect["cols"] = rect["col1"] - rect["col0"] + 1
        rect["cells"] = rect["cols"] * rect["rows"]
    return out


def picture_rects(decoder, cell):
    """The authoritative picture geometry, from the decoder's own placements.

    The text runs above answer "where would the terminal put the pictures" when all you have is a
    capture; this answers the same question from a stream this tool ran itself, where the placement
    rects are exact. Two sources, one shape, so a scenario can assert on either.
    """
    out = []
    # krd re-places only what it repainted, and an image keeps its id for its lifetime, so the last
    # placement of each id (with `a=d` applied) is where that picture is *now*. Anything earlier is
    # history: after a resize it is a rectangle that no longer exists, and counting it as a picture
    # is how a resize bug reads as a layout with too many cards.
    for placement in decoder.live_placements().values():
        if not placement.unicode_placeholder:
            continue
        image = decoder.images().get(placement.image_id)
        if image is not None and image.w <= 1 and image.h <= 1:
            continue  # the U=1 capability probe: a 1x1 image placed to ask "can you fit?"
        out.append({
            "row0": placement.row, "row1": placement.row + placement.rows - 1,
            "col0": placement.col, "col1": placement.col + placement.cols - 1,
            "rows": placement.rows, "cols": placement.cols,
            "cells": placement.rows * placement.cols,
            "image": placement.image_id,
        })
    return out
