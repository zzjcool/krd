#!/usr/bin/env python3
"""What `--scale` buys, and proof that it does not move the pointer (issue #60).

Two halves, both against the running Mac (this needs Screen Recording and Accessibility, so run it
on the machine being mirrored, not over ssh from the one you are looking at):

    python3 probe/scale_probe.py --bytes      # bytes/s, CPU, raw frame size, placement cells
    python3 probe/scale_probe.py --pointer    # click the same terminal pixel at two scales and
                                              # compare TextEdit's caret (needs probe/ax_caret_probe)
    python3 probe/scale_probe.py --all

`--bytes` runs krd under a pty with a real window size (a bare `pty.fork()` reports 0x0, and krd then
falls back to a 1x1-cell pane), keeps every byte krd writes so the kitty placements can be read back,
and samples `ps -o %cpu` during the run. `--pointer` aims at a point inside TextEdit's frontmost text
area, converts it to the terminal pixel krd would expect, clicks it, and reads the caret back: the
caret must be the same at scale 1 and scale 0.5, and two different points must give different carets
or the test proves nothing.
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

DISPLAY = (1920, 1200)          # only used to turn a screen point into a terminal pixel below
COLS, ROWS = 60, 24
CELL = (17, 33)
PANE = (COLS * CELL[0], (ROWS * 4 // 5) * CELL[1])   # the picture fills 60x19 cells here


def run(binary, flags, seconds, out, log, stats=None, mouse=(), cell=CELL, pane=(COLS, ROWS)):
    """krd under a pty; every byte it writes lands in `out` so escapes can be parsed afterwards."""
    argv = [binary, "--cell", "%dx%d" % cell, "--log", log] + flags
    if stats:
        argv += ["--stats-json", stats]
    pid, master = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, dict(os.environ))
        os._exit(127)
    fcntl.ioctl(master, termios.TIOCSWINSZ,
                struct.pack("HHHH", pane[1], pane[0], pane[0] * cell[0], pane[1] * cell[1]))
    chunks, cpu = [], []
    stop = threading.Event()

    def drain():
        while not stop.is_set():
            ready, _, _ = select.select([master], [], [], 0.2)
            if ready:
                try:
                    data = os.read(master, 1 << 16)
                except OSError:
                    break
                if not data:
                    break
                chunks.append(data)

    def sample_cpu():
        while not stop.is_set():
            value = subprocess.run(["ps", "-o", "%cpu=", "-p", str(pid)],
                                   capture_output=True, text=True).stdout.strip()
            if value:
                cpu.append(float(value))
            time.sleep(2)

    threading.Thread(target=drain, daemon=True).start()
    threading.Thread(target=sample_cpu, daemon=True).start()
    time.sleep(1.4)
    for event in mouse:
        if isinstance(event, float):
            time.sleep(event)
        else:
            try:
                os.write(master, event.encode())
            except OSError:
                break
    spent = sum(e for e in mouse if isinstance(e, float))
    time.sleep(max(0.0, seconds - 1.4 - spent))
    stop.set()
    os.kill(pid, 15)
    # krd's SIGTERM path stops the stream first, and `stopCapture()` can hang (issues #44, #54), so a
    # graceful exit gets a deadline like everything else that waits on ScreenCaptureKit.
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
    with open(out, "wb") as handle:
        handle.write(b"".join(chunks))
    return cpu


def stats_rows(path):
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.strip():
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return rows


def stream_shape(path):
    """Image pixel sizes and placement cell boxes, as a terminal would see them."""
    data = open(path, "rb").read()
    images = sorted({(int(w), int(h)) for w, h in re.findall(rb"Gf=\d+,s=(\d+),v=(\d+)", data)})
    boxes = sorted({(int(c), int(r)) for c, r in re.findall(rb"a=p,q=\d,C=1,c=(\d+),r=(\d+)", data)})
    return images, boxes


def typing(chars, interval=0.05):
    """A deterministic workload: krd is fed printable keys, which it injects into the frontmost app
    (TextEdit with a document open). A still desktop sends almost no bytes, and an AppleScript that
    scrolls a terminal needs Automation permission this ssh session does not have, so typing is the
    one thing that is both steady and identical across runs. It is also the content `--scale` hurts
    most: half the pixels per glyph is visibly soft."""
    events = []
    for _ in range(chars):
        events.append("a")
        events.append(interval)
    return events


def measure(binary, scales, seconds, work, events=()):
    print("| scale | capture px | bytes/s | CPU | raw frame | tile image px | placement cells |")
    print("|---:|---|---:|---:|---|---|---|")
    for scale in scales:
        tag = ("s" + scale.replace(".", "")).replace(" ", "")
        stats = os.path.join(work, "stats-%s.jsonl" % tag)
        stream = os.path.join(work, "stream-%s.bin" % tag)
        record = os.path.join(work, "rec-%s" % tag)
        cpu = run(binary, ["--scale", scale, "--record", record, "--record-frames", "2",
                           "--stats-json", stats], seconds, stream,
                  os.path.join(work, "log-%s.txt" % tag), mouse=events)
        rows = stats_rows(stats)
        span = rows[-1]["t"] - rows[0]["t"]
        sent = sum(r["kb"] for r in rows)
        images, boxes = stream_shape(stream)
        raw = 0
        try:
            raw = os.path.getsize(os.path.join(record, "000000.raw"))
        except OSError:
            pass
        big = max(images, key=lambda size: size[0] * size[1]) if images else (0, 0)
        print("| %s | %dx%d | %.2f MB/s | %s | %d B | %s | %s |"
              % (scale, rows[-1]["px"][0], rows[-1]["px"][1], sent / span / 1024,
                 ("%.1f%%" % (sum(cpu) / len(cpu))) if cpu else "-", raw,
                 "%dx%d" % big,
                 ", ".join("%dx%d" % b for b in (sorted(boxes, key=lambda b: -b[0] * b[1])[:2]))
                 or "-"))
    print("\n(bytes/s is `kb` summed over the run's stats lines; a still desktop is mostly framing, "
          "so the ratio is smaller than --bench's payload ratio)")


def caret(binary):
    out = subprocess.run([binary], capture_output=True, text=True).stdout.strip().splitlines()
    if not out:
        return None, None
    location = re.search(r"location=(\d+)", out[0])
    frame = re.search(r"frame=(\d+),(\d+) (\d+)x(\d+)", out[0])
    if not location or not frame:
        return None, None
    return int(location.group(1)), tuple(int(v) for v in frame.groups())


def pointer(binary, caret_binary, scales=(1, 0.5)):
    if not os.path.exists(caret_binary):
        print("pointer: %s missing (compile probe/ax_caret_probe.swift first)" % caret_binary)
        return
    points = {"A": (60, 20), "B": (330, 210)}          # offsets inside the text area
    _, frame = caret(caret_binary)
    if frame is None:
        print("pointer: no TextEdit text area (open a document first)")
        return
    print("text area %s" % (frame,))
    results = {}
    for name, (dx, dy) in points.items():
        point = (frame[0] + dx, frame[1] + dy)
        pixel = (round(point[0] / DISPLAY[0] * PANE[0]), round(point[1] / DISPLAY[1] * PANE[1]))
        for scale in scales:
            subprocess.run(["osascript", "-e", 'tell application "TextEdit" to activate'],
                           capture_output=True)
            time.sleep(0.7)
            run(binary, ["--scale", str(scale), "--debug"], 6,
                os.path.join(os.environ.get("TMPDIR", "/tmp"), "scale-click.bin"),
                os.path.join(os.environ.get("TMPDIR", "/tmp"), "scale-click.log"),
                mouse=[1.4, "\x1b[<0;%d;%dM" % pixel, 0.15, "\x1b[<0;%d;%dm" % pixel, 0.9])
            time.sleep(0.3)
            results[(name, scale)] = caret(caret_binary)[0]
            print("target %s %-10s pixel %-10s scale %-4s -> caret %s"
                  % (name, point, pixel, scale, results[(name, scale)]))
    same = all(results[(n, s)] == results[(n, scales[0])] for n in points for s in scales[1:])
    distinct = results[("A", scales[0])] != results[("B", scales[0])]
    print("\nthe pointer is not moved by --scale: %s" % same)
    print("the two targets give different carets (the test can tell): %s" % distinct)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/release/krd")
    parser.add_argument("--caret", default="/tmp/ax-caret")
    parser.add_argument("--scales", default="1,0.5")
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--work", default="/tmp/krd-scale-probe")
    parser.add_argument("--bytes", action="store_true")
    parser.add_argument("--type", type=int, default=0,
                        help="feed this many keystrokes into the frontmost app, so bytes/s is "
                             "measured on changing content (TextEdit open and frontmost)")
    parser.add_argument("--pointer", action="store_true")
    parser.add_argument("--all", action="store_true")
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    if args.bytes or args.all or not (args.bytes or args.pointer):
        measure(args.binary, args.scales.split(","), args.seconds, args.work,
                typing(args.type))
    if args.pointer or args.all:
        print()
        pointer(args.binary, args.caret)


if __name__ == "__main__":
    main()
