#!/usr/bin/env python3
"""Put krd behind a link that cannot carry the picture, and watch `--scale auto` react (issue #64).

The pty krd writes to is drained at a fixed rate (a token bucket in the reader), which is the same
thing a slow ssh link does to krd: `write(2)` blocks, frames go late, and nothing else in the
pipeline knows why. The rate can be changed part-way through, so one run shows both directions.

    python3 probe/pipe_probe.py --rates 1.5,40 --seconds 40,40
    python3 probe/pipe_probe.py --binary .build/release/krd --work /tmp/krd-pipe

Needs a capture that actually produces bytes: put something colour-heavy on screen (a photo in
Preview, full screen) -- a still desktop sends almost nothing and nothing will ever be late.
"""

import argparse
import fcntl
import json
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

COLS, ROWS = 60, 24
CELL = (17, 33)


def sweep(interval=0.1):
    """Pointer moves across the picture. With `--zoom 2 --zoom-follow` every pan is a full-frame
    change, which is the cheapest way to keep a *photo* arriving a few times a second: a still image
    sends nothing after its first frame, so a backpressure test on one measures nothing."""
    while True:
        for i in range(10_000):
            yield "\x1b[<35;%d;%dM" % (60 + (i * 37) % 900, 60 + (i * 53) % 540)
            yield interval


def run(binary, flags, phases, out, log, stats, cell=CELL, pane=(COLS, ROWS), sweep_input=False,
        click=None):
    """krd under a pty whose drain rate follows `phases` [(seconds, bytes_per_second), ...]."""
    argv = [binary, "--cell", "%dx%d" % cell, "--log", log, "--stats-json", stats] + flags
    pid, master = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, dict(os.environ))
        os._exit(127)
    fcntl.ioctl(master, termios.TIOCSWINSZ,
                struct.pack("HHHH", pane[1], pane[0], pane[0] * cell[0], pane[1] * cell[1]))

    limit = [phases[0][1]]
    read = [0]
    timeline = []
    stop = threading.Event()

    def drain():
        tokens, last = 0.0, time.time()
        while not stop.is_set():
            now = time.time()
            tokens = min(tokens + (now - last) * limit[0], limit[0] * 0.25 + 64 * 1024)
            last = now
            if tokens < 1024:
                stop.wait(0.01)
                continue
            ready, _, _ = select.select([master], [], [], 0.02)
            if not ready:
                continue
            try:
                data = os.read(master, int(min(tokens, 1 << 16)))
            except OSError:
                break
            if not data:
                break
            tokens -= len(data)
            read[0] += len(data)
            timeline.append((time.time(), len(data), limit[0]))

    def feed():
        if not sweep_input:
            return
        events = sweep()
        while not stop.is_set():
            try:
                os.write(master, next(events).encode())
            except OSError:
                return
            time.sleep(next(events))

    def click_later():
        # A click through the same pty, after the governor has had time to move: the point is that the
        # pointer still lands where it should once the picture is being captured at another scale.
        delay, (px, py) = click
        time.sleep(delay)
        for suffix in ("M", "m"):
            try:
                os.write(master, ("\x1b[<0;%d;%d%s" % (px, py, suffix)).encode())
            except OSError:
                return
            time.sleep(0.15)

    threading.Thread(target=drain, daemon=True).start()
    started = time.time()
    time.sleep(1.5)          # let the first frame through before the pipe is judged
    threading.Thread(target=feed, daemon=True).start()
    if click:
        threading.Thread(target=click_later, daemon=True).start()
    for seconds, rate in phases:
        limit[0] = rate
        deadline = time.time() + seconds
        while time.time() < deadline:
            time.sleep(0.2)
    stop.set()
    os.kill(pid, 15)
    deadline = time.time() + 3
    while time.time() < deadline:
        if os.waitpid(pid, os.WNOHANG)[0]:
            break
        time.sleep(0.05)
    else:
        os.kill(pid, 9)
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    try:
        os.close(master)
    except OSError:
        pass
    return started, time.time() - started, read[0]


def report(log, stats, started, phases):
    rows = []
    for line in open(stats, encoding="utf-8", errors="replace"):
        if line.strip():
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    changes = []
    restarts = 0
    for line in open(log, encoding="utf-8", errors="replace"):
        if "scale " in line and ("pipe is behind" in line or "pipe has headroom" in line):
            changes.append(line.strip())
        if "restarting the capture stream" in line or "capture stream stopped" in line:
            restarts += 1
    print("| t | drain MB/s | capture px | scale | late | fps | MB/s |")
    print("|---:|---:|---|---:|---:|---:|---:|")
    phase_end, index = 0.0, 0
    for row in rows:
        while index < len(phases) and row["t"] > phase_end + phases[index][0]:
            phase_end += phases[index][0]
            index += 1
        rate = phases[min(index, len(phases) - 1)][1] / 1e6
        late = row.get("late", 0)
        frames = row.get("frames", 0)
        share = ("%d%%" % (100 * late / frames)) if frames else "-"
        print("| %.0f | %.1f | %dx%d | %s | %s (%d/%d) | %d | %.2f |"
              % (row["t"], rate, row["px"][0], row["px"][1], row.get("scale", 1),
                 share, late, frames, row["tiles"], row["mbps"]))
    print()
    for line in changes:
        print(line)
    print("stream restarts during the whole run: %d" % restarts)
    return changes, restarts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/release/krd")
    parser.add_argument("--work", default="/tmp/krd-pipe")
    parser.add_argument("--rates", default="1.5,40", help="drain rates in MB/s, one per phase")
    parser.add_argument("--seconds", default="40,40", help="seconds per phase")
    parser.add_argument("--extra", default="", help="extra krd flags")
    parser.add_argument("--pane", default="60x24", help="pane size in cells (default 60x24)")
    parser.add_argument("--click", default="", help="click this terminal pixel mid-run, e.g. 160,87")
    parser.add_argument("--click-after", type=float, default=18.0,
                        help="when to click, seconds into the run (default 18: after a downgrade)")
    parser.add_argument("--sweep", action="store_true",
                        help="move the pointer so a photo keeps changing (use with "
                             "'--extra \"--zoom 2 --zoom-follow\"')")
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    rates = [float(v) * 1e6 for v in args.rates.split(",")]
    seconds = [float(v) for v in args.seconds.split(",")]
    phases = list(zip(seconds, rates))
    flags = ["--scale", "auto", "--debug", "--fps", "20"] + args.extra.split()
    log = os.path.join(args.work, "krd.log")
    stats = os.path.join(args.work, "stats.jsonl")
    started, elapsed, total = run(args.binary, flags, phases, os.path.join(args.work, "stream.bin"),
                                  log, stats, pane=tuple(int(v) for v in args.pane.split("x")),
                                  sweep_input=args.sweep,
                                  click=((args.click_after, tuple(int(v) for v in args.click.split(",")))
                                         if args.click else None))
    print("%.1f s, %d bytes read (%.2f MB/s average)\n" % (elapsed, total, total / elapsed / 1e6))
    _, restarts = report(log, stats, started, phases)
    return 0 if restarts == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
