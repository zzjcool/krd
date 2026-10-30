#!/usr/bin/env python3
"""Where a click in the picture actually lands, in window mode (issues #69, #71).

A mirrored window has to be *operable*, and "the click lands where it looks" is not something a log
line can prove: the log says which screen point krd posted, not whether the app got it and whether it
was the right one. So this probes it with a control that has a visible, countable side effect -- the
mirrored window's own button -- and counts before/after:

    python3 probe/click_probe.py --binary .build/release/krd --window 530 --control "New Tab"

It needs a window whose button is safe to press repeatedly (Safari's "New Tab" opens a tab). The pane
sizes and scales are the axes that used to break: the picture's placement is `min(pane/src)` cells for
the *screen*, while `--scale` only decides how many pixels are sent, so a click at a given terminal
pixel must reach the same screen point at every scale and in every pane.

Run it on the machine being mirrored (Screen Recording and Accessibility), not over ssh from the
machine you are looking at.
"""

import argparse
import fcntl
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import threading
import time

CELL = (17, 33)


def tabs(app="Safari"):
    out = subprocess.run(["osascript", "-e", 'tell application "%s" to count tabs of window 1' % app],
                         capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else -1


def window_frame(binary, window):
    listing = subprocess.run([binary, "--list"], capture_output=True, text=True).stdout
    match = re.search(r"window %d  @(-?\d+),(-?\d+) (\d+)x(\d+)" % window, listing)
    if not match:
        raise SystemExit("window %d is not in --list" % window)
    return tuple(int(v) for v in match.groups())


def control_centre(binary, app, name, window_id):
    """The control's centre, from whichever of the app's windows is the one being mirrored.

    `ax find` walks one window, and an app can have several (a detached download bubble in the front
    is enough to hide the button), so walk the app's windows and keep the one whose frame is the
    mirrored window's."""
    listing = subprocess.run([binary, "--list"], capture_output=True, text=True).stdout
    mirrored = re.search(r"window %d  @(-?\d+),(-?\d+) (\d+)x(\d+)" % window_id, listing)
    wanted = tuple(int(v) for v in mirrored.groups()) if mirrored else None
    for index in range(6):
        out = subprocess.run([binary, "ax", "find", "--app", app, "--window", str(index), name],
                             capture_output=True, text=True).stdout
        match = re.search(r"\[(-?\d+),(-?\d+) (\d+)x(\d+)\]", out)
        if not match:
            continue
        x, y, w, h = (int(v) for v in match.groups())
        if wanted is None:
            return x + w / 2, y + h / 2
        wx, wy, ww, wh = wanted
        if wx <= x <= wx + ww and wy <= y <= wy + wh:
            return x + w / 2, y + h / 2
    raise SystemExit("control %r not found in %s" % (name, app))


def geometry(log):
    """The placement krd itself decided on: `-> 512x339 px in 61x21 cells`."""
    for line in open(log, encoding="utf-8", errors="replace"):
        match = re.search(r"-> (\d+)x(\d+) px in (\d+)x(\d+) cells", line)
        if match:
            return tuple(int(v) for v in match.groups())
    return None


def run(binary, window, cols, rows, scale, pixel, seconds=6.0, work="/tmp/click-probe"):
    os.makedirs(work, exist_ok=True)
    log = os.path.join(work, "krd-%dx%d-s%s.log" % (cols, rows, scale))
    argv = [binary, "--window", str(window), "--debug", "--log", log, "--scale", str(scale)]
    pid, master = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, dict(os.environ))
        os._exit(127)
    # A real pane size, or krd falls back to 1x1 cells and nothing below applies.
    fcntl.ioctl(master, termios.TIOCSWINSZ,
                struct.pack("HHHH", rows, cols, cols * CELL[0], rows * CELL[1]))
    stop = threading.Event()

    def drain():
        while not stop.is_set():
            readable, _, _ = select.select([master], [], [], 0.2)
            if readable:
                try:
                    os.read(master, 1 << 16)
                except OSError:
                    return

    threading.Thread(target=drain, daemon=True).start()
    time.sleep(3.0)
    shape = geometry(log)
    if shape is None:
        stop.set()
        raise SystemExit("krd never logged its geometry: %s" % log)
    for suffix in ("M", "m"):
        os.write(master, ("\x1b[<0;%d;%d%s" % (pixel[0], pixel[1], suffix)).encode())
        time.sleep(0.15)
    time.sleep(1.5)
    stop.set()
    os.kill(pid, 15)
    time.sleep(1.0)
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    lines = [l.strip() for l in open(log, encoding="utf-8", errors="replace")
             if "mouse left-down" in l or "outside the picture" in l]
    return shape, lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/release/krd")
    parser.add_argument("--window", type=int, default=530)
    parser.add_argument("--app", default="Safari")
    parser.add_argument("--control", default="New Tab")
    parser.add_argument("--panes", default="30x12,61x21,88x30")
    parser.add_argument("--scales", default="1,0.5,0.25")
    parser.add_argument("--band", action="store_true",
                        help="also click in the band the aspect leaves to the terminal")
    args = parser.parse_args()

    centre = control_centre(args.binary, args.app, args.control, args.window)
    wx, wy, ww, wh = window_frame(args.binary, args.window)
    print("control %r centre (%d, %d), window %d @%d,%d %dx%d; %d tabs now"
          % (args.control, centre[0], centre[1], args.window, wx, wy, ww, wh, tabs(args.app)))
    print("| pane | scale | frame px | placement | click px | tabs | verdict |")
    print("|---|---:|---|---|---|---:|---|")
    for pane in args.panes.split(","):
        cols, rows = (int(v) for v in pane.split("x"))
        for scale in args.scales.split(","):
            # The pixel the user would click: the control's place inside the window, in the
            # placement's own pixels (which is what SGR-Pixels coordinates are).
            probe, _ = run(args.binary, args.window, cols, rows, scale, (1, 1))
            pixel = (round((centre[0] - wx) / ww * int(probe[2]) * CELL[0]),
                     round((centre[1] - wy) / wh * int(probe[3]) * CELL[1]))
            before = tabs(args.app)
            shape, lines = run(args.binary, args.window, cols, rows, scale, pixel)
            time.sleep(1.2)
            after = tabs(args.app)
            verdict = "LANDED" if after > before else "missed"
            print("| %s | %s | %dx%d | %dx%d | %s | %d -> %d | %s |"
                  % (pane, scale, shape[0], shape[1], shape[2], shape[3], pixel, before, after, verdict))
            if affected := [l for l in lines if "outside the picture" in l]:
                print("   %s" % affected[-1])
    if args.band:
        print("\nthe band the aspect leaves to the terminal (pane 88x14: the picture is 41 cells wide)")
        for scale in args.scales.split(","):
            shape, lines = run(args.binary, args.window, 88, 14, scale, (80 * CELL[0], 5 * CELL[1]))
            print("  scale %-4s placement %dx%d: %s"
                  % (scale, shape[2], shape[3],
                     "\n    ".join(lines) or "nothing logged"))


if __name__ == "__main__":
    main()
