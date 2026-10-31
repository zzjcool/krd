#!/usr/bin/env python3
"""A SIGWINCH burst against a running `krd`, and what each step cost on the wire.

Issue #89: dragging a window edge fires 30-60 `SIGWINCH`es a second, and every one of them used to
re-layout the picture, clear the terminal (`ESC _ G a=d,d=a ESC \\` plus `ESC[2J`) and re-transmit
every tile. The issue's measurement, for a 40-event drag in ~1.4 s:

    before the fix   40 clears / 4,564 image sends -- one full repaint per event
    after the fix    one re-layout and one repaint: ~1 clear, one screen's worth of sends

This script is the ruler for those numbers. It puts krd on a pty, steps `TIOCSWINSZ` on the master
40 times at 30 Hz (grow, shrink, grow, ... so every event really moves the grid), drains the pty
throughout, and counts what came out.

    python3 bench/loop-resize-storm.py 40 .build/release/krd \\
        --pane 100x40 --cell 10x20 --fps 20 --debug --log /tmp/storm.log
    # -> {"burst_events": 40, "burst_seconds": 1.311, "delete_all": 1, "clear_2J": 1,
    #     "images_transmitted": 72, "frames": 71, "bytes_total": 931337,
    #     "exit_status": "killed", "resize_lines": 1, "grid_lines": 1}

What is counted, over every byte drained from the pty for the whole window (burst + `--settle`):

    delete_all           the kitty delete-all APC  ESC _ G a=d,d=a ESC \\  -- one per clear
    clear_2J             ESC [ 2 J                                        -- one per clear
    images_transmitted   transmission APCs: one per tile image, NOT one per 4096-char chunk.
                         krd's control list is `f=..,s=..,v=..,a=t,...,i=<id>;`, so the action is
                         not the first pair: an `a=t`/`a=T` pair anywhere in the comma-separated
                         list before the `;` counts, and a continuation chunk (`Gm=1;<base64>`,
                         no control list at all) does not. The 1x1 geometry probe transmits with
                         `a=t,i=31` too, so a run carries +1 for it.
    frames               ESC [ ? 2026 h -- the synchronised-update openers, i.e. paints
    bytes_total          every drained byte

`--debug --log PATH` is what makes krd write the `resize:` lines (`--log` alone gets the file, but
the resize line is gated on `--debug`). `resize_lines` counts `^resize:`; `grid_lines` counts the
relayout line *as the tree writes it*, `^krd: mirror grid` -- one per accepted `applyLayout`, so
the two columns answer "how many resizes did krd accept" from both sides of the fork. (The sketch
for this harness said `^mirror grid`, but the line carries a `krd: ` prefix -- anchored there the
column could only ever read 0.)

The pty is only drained, never answered, and krd runs `--mock`: nothing here needs a window server
or a screen recording grant, so a busy machine measures krd and not the desktop. Sizes are clamped
to cols 60..160 / rows 20..60, so a long burst cannot ask for a grid no terminal could show; the
pixel fields stay 0 (unknown), which is what a real `TIOCSWINSZ` from a drag sends. `--raw PATH`
dumps the drained stream when a count needs explaining.

krd never outlives the harness: a `finally:` SIGKILLs its process group, and the whole run is
capped at events/30 + settle + 10 s.
"""
import argparse
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

RATE_HZ = 30.0                  # the issue's drag rate: 40 events in ~1.4 s
INTERVAL = 1.0 / RATE_HZ
DRAIN_WAIT = 0.02               # never block longer than this: the pty has to keep draining
READ_CHUNK = 65536

APC_OPEN = b"\x1b_G"
APC_CLOSE = b"\x1b\\"
DELETE_ALL = b"\x1b_Ga=d,d=a\x1b\\"
CLEAR_2J = b"\x1b[2J"
SYNC_START = b"\x1b[?2026h"

COLS_RANGE = (60, 160)          # a drag cannot ask for a grid outside this
ROWS_RANGE = (20, 60)


# ------------------------------------------------------------------ arguments

def parse_pair(text, what):
    """`100x40` -> (100, 40). Both `--pane COLSxROWS` and `--cell WxH` arrive this way."""
    parts = text.lower().split("x")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise argparse.ArgumentTypeError(f"{what} wants AxB, got {text!r}")
    try:
        return int(parts[0]), int(parts[1])
    except ValueError:
        raise argparse.ArgumentTypeError(f"{what} wants two whole numbers, got {text!r}")


def pane_arg(text):
    cols, rows = parse_pair(text, "--pane COLSxROWS")
    if cols < 2 or rows < 2:
        raise argparse.ArgumentTypeError(f"--pane wants at least 2x2, got {text!r}")
    return cols, rows


def cell_arg(text):
    width, height = parse_pair(text, "--cell WxH")
    if width <= 0 or height <= 0:
        raise argparse.ArgumentTypeError(f"--cell wants positive pixels, got {text!r}")
    return width, height


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("events", type=int,
                    help="TIOCSWINSZ steps to send at 30 Hz (the issue's unit is 40)")
    ap.add_argument("binary", help="the krd binary to drive (.build/release/krd)")
    ap.add_argument("--pane", type=pane_arg, default=(100, 40), metavar="COLSxROWS",
                    help="base pane the pty opens at (default 100x40)")
    ap.add_argument("--cell", type=cell_arg, default=(10, 20), metavar="WxH",
                    help="cell size handed to krd (default 10x20)")
    ap.add_argument("--fps", type=int, default=20, help="frame rate handed to krd (default 20)")
    ap.add_argument("--settle", type=float, default=2.5,
                    help="seconds of quiet after the burst, before the kill (default 2.5)")
    ap.add_argument("--debug", action="store_true", help="pass --debug to krd")
    ap.add_argument("--raw", default=None, metavar="PATH",
                    help="write every drained byte here (to read a crash message krd wrote)")
    ap.add_argument("--log", default=None, metavar="PATH",
                    help="pass --log PATH to krd (and count its resize/mirror-grid lines)")
    args = ap.parse_args()
    if args.events < 0:
        ap.error("events must be zero or more")
    if args.fps < 1:
        ap.error("--fps must be at least 1")
    if args.settle < 0:
        ap.error("--settle must be zero or more")
    return args


# ------------------------------------------------------------------ the pty

def set_winsize(fd, cols, rows):
    """`TIOCSWINSZ` is (rows, cols, xpixels, ypixels); 0 pixels = "the terminal does not know"."""
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def spawn_setup(slave):
    """The child's half: its own process group, and the pty as its *controlling* terminal.

    `setsid()` alone is not enough. Without `TIOCSCTTY` the pty has no session attached to it, so
    the kernel has nobody to send `SIGWINCH` to when the master's window size changes: measured
    with a sleeping child, `setsid` only -> 0 signals for 6 steps, `setsid` + `TIOCSCTTY` -> 6.
    """
    def setup():
        os.setsid()
        try:
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        except OSError:
            pass                                    # still runnable, just deaf to resizes
    return setup


def drain(fd, buffer):
    """Read everything the pty holds right now. False at EOF, i.e. krd's side is gone."""
    while True:
        try:
            chunk = os.read(fd, READ_CHUNK)
        except (BlockingIOError, InterruptedError):
            return True                             # nothing left right now, not an error
        except OSError:
            return False                            # EIO: every slave fd is closed
        if not chunk:
            return False
        buffer += chunk


def clamp(value, low, high):
    return low if value < low else high if value > high else value


def burst_steps(events, cols, rows):
    """+1, -1, +2, -2, ... cells around the base, so no two events ask for the same grid."""
    steps = []
    for i in range(events):
        k = i // 2 + 1
        sign = 1 if i % 2 == 0 else -1
        steps.append((clamp(cols + sign * k, *COLS_RANGE), clamp(rows + sign * k, *ROWS_RANGE)))
    return steps


# ------------------------------------------------------------------ counting

def is_transmission(payload):
    """Was this APC a kitty *transmission*?

    The control list is comma-separated and stops at the `;` that introduces the base64 payload.
    krd writes `f=<ch>,s=<w>,v=<h>,a=t[,o=z],q=<q>,i=<id>` -- the action is not the first pair,
    so the pair is looked for in the whole list. A chunk continuation (`m=1;<base64>`) has no
    control list beyond `m=`, so it cannot count: that is what makes this one per image.
    """
    control = payload.split(b";", 1)[0]
    return any(field in (b"a=t", b"a=T") for field in control.split(b","))


def count_transmissions(buffer):
    """One per transmission APC: split on the introducer, keep what precedes the next terminator."""
    total = 0
    for piece in bytes(buffer).split(APC_OPEN)[1:]:
        end = piece.find(APC_CLOSE)
        if end < 0:
            continue                                # the terminator never arrived: not an APC
        if is_transmission(piece[:end]):
            total += 1
    return total


def count_log_lines(path, pattern):
    """Lines of krd's log matching `pattern`; 0 when the file was never written."""
    try:
        with open(path, "rb") as handle:
            text = handle.read()
    except OSError:
        return 0
    return len(re.findall(pattern, text, re.MULTILINE))


# ------------------------------------------------------------------ main

def main():
    args = parse_args()
    if not os.path.exists(args.binary):
        sys.exit(f"no binary at {args.binary} - swift build -c release first")

    cols, rows = args.pane
    cell_w, cell_h = args.cell
    argv = [args.binary, "--mock",
            "--pane", f"{cols}x{rows}", "--cell", f"{cell_w}x{cell_h}", "--fps", str(args.fps)]
    if args.debug:
        argv.append("--debug")
    if args.log:
        argv += ["--log", args.log]

    steps = burst_steps(args.events, cols, rows)
    master, slave = pty.openpty()
    set_winsize(slave, cols, rows)
    try:
        proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                                preexec_fn=spawn_setup(slave), close_fds=True)
    except OSError as exc:
        os.close(master)
        os.close(slave)
        sys.exit(f"cannot run {argv[0]}: {exc}")
    os.close(slave)
    os.set_blocking(master, False)

    buffer = bytearray()                            # every byte, kept until the window ends
    sent = 0
    burst_seconds = 0.0
    capped = False
    child_gone = False
    settle_until = None
    exit_status = "killed"
    t0 = time.perf_counter()
    # The cap covers the whole run, the wait for the first frame included: events/30 + settle + 10.
    cap_at = t0 + len(steps) * INTERVAL + args.settle + 10.0
    try:
        # Wait for the first committed frame before the first step: `krd` installs its `SIGWINCH`
        # source after it has laid out and started the stream, and the default disposition of
        # `SIGWINCH` is "ignore" -- so a burst that starts at t=0 is measured against the startup,
        # not the resize path (measured: 8 steps at 30 Hz inside the first 0.24 s gave 0 handled
        # resizes). Also bounded by the cap, so a krd that never paints cannot run away.
        ready_at = min(t0 + 15.0, cap_at)
        while SYNC_START not in buffer and time.perf_counter() < ready_at:
            if not drain(master, buffer):
                child_gone = True
                break
            try:
                select.select([master], [], [], 0.02)
            except (OSError, ValueError):
                child_gone = True
                break
        started = time.perf_counter()
        next_send = started
        while True:
            now = time.perf_counter()
            if child_gone:
                break                                       # nothing left to measure
            if sent >= len(steps):
                # The burst is over: the window is `settle` seconds of quiet, then the kill.
                if settle_until is None:
                    settle_until = now + args.settle        # zero events: quiet from the start
                if child_gone or now >= settle_until:
                    break
            elif now >= next_send:
                try:
                    set_winsize(master, *steps[sent])
                except OSError:
                    child_gone = True                       # the pty is gone: nothing left to size
                    break
                sent += 1
                burst_seconds = now - started
                next_send = started + sent * INTERVAL      # deadline from the start: no drift
                if sent == len(steps):
                    settle_until = now + args.settle        # the quiet window starts at the last step
            if now >= cap_at:
                capped = True
                break
            if not child_gone and proc.poll() is not None:
                child_gone = True                              # krd died: keep its bytes, stop
            if sent < len(steps):
                wait = next_send - time.perf_counter()
            else:
                wait = settle_until - time.perf_counter()
            wait = max(0.0, min(wait, DRAIN_WAIT))
            if child_gone:
                time.sleep(wait)
            else:
                try:
                    select.select([master], [], [], wait)
                except (OSError, ValueError):
                    child_gone = True
            if not drain(master, buffer):
                child_gone = True
    finally:
        # The settle window's own tail, taken while krd is still alive: a pty whose last slave
        # fd has closed is *hung up*, and bytes still queued on the master are dropped.
        drain(master, buffer)
        alive = proc.poll() is None
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)     # never leave krd running
        except OSError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        drain(master, buffer)                                   # whatever it wrote on the way out
        os.close(master)
        exit_status = "killed" if alive or proc.returncode is None else proc.returncode

    result = {
        "burst_events": sent,
        "burst_seconds": round(burst_seconds, 3),
        "delete_all": buffer.count(DELETE_ALL),
        "clear_2J": buffer.count(CLEAR_2J),
        "images_transmitted": count_transmissions(buffer),
        "frames": buffer.count(SYNC_START),
        "bytes_total": len(buffer),
        "exit_status": exit_status,
    }
    if args.raw is not None:
        with open(args.raw, "wb") as handle:
            handle.write(buffer)
    if args.log is not None:
        result["resize_lines"] = count_log_lines(args.log, rb"^resize:")
        result["grid_lines"] = count_log_lines(args.log, rb"^krd: mirror grid")
    if capped:
        print(f"note: hit the {len(steps) * INTERVAL + args.settle + 10:.0f} s cap after "
              f"{sent}/{len(steps)} events - the counts above are a truncated burst",
              file=sys.stderr)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
