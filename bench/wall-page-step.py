#!/usr/bin/env python3
"""Measure one **page step** on the wall: milliseconds and bytes, per step (issue #100).

The wall's own unit of cost is one page step - one click on the bar's `v`, or one wheel notch over
the shelf - so this drives a real `krd --wall` in a pty, sends `--pages` page steps, and reports for
each step:

  * `ms`     - key written -> last byte of the frame that answered it (the reader's latency)
  * `bytes`  - what actually crossed the pty for that frame
  * `payload`/`panels`/`reused` - the same frame read out of the `--log` file, so the pty number can
    be attributed (payload = the zlib blobs; the rest is escapes and the placeholder grid)

No pty emulation and no screenshot: the bytes are the measurement.

    python3 bench/wall-page-step.py --binary .build/release/krd --pages 3 --tag after
    python3 bench/wall-page-step.py --binary /tmp/krd-before --pages 3 --tag before

Needs Screen Recording granted (it captures a real desktop) and a quiet machine: another lane
compiling moves the `ms` number, the `bytes` number does not care.
"""

import argparse
import fcntl
import json
import os
import pty
import re
import select
import statistics
import struct
import subprocess
import sys
import termios
import time


def drain(master, quiet, cap):
    """Read the pty until it has been quiet for `quiet` seconds, or `cap` total.

    Returns (bytes_read, first_byte_at, last_byte_at). A frame is delimited by silence: the wall
    writes one frame per repaint and then waits for the next tick or key.
    """
    total = 0
    first = last = None
    deadline = time.monotonic() + cap
    while True:
        timeout = quiet if first is not None else cap
        left = deadline - time.monotonic()
        if left <= 0:
            break
        r, _, _ = select.select([master], [], [], min(timeout, left))
        if not r:
            if first is not None:
                break
            continue
        try:
            chunk = os.read(master, 1 << 16)
        except OSError:
            break
        if not chunk:
            break
        now = time.monotonic()
        if first is None:
            first = now
        last = now
        total += len(chunk)
    return total, first, last


PAYLOAD = re.compile(r"krd: wall slot (\d+) picture (\d+)x(\d+) px -> (\d+) B payload")
REUSED = re.compile(r"krd: wall slot (\d+) picture reused")
SLOTW = re.compile(r"krd: wall slot (\d+) <- (display|window) (\S+)(.*)")
PAINT = re.compile(r"krd: wall paint (.*)")


def read_log(path, offset):
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read()
    except FileNotFoundError:
        return "", offset
    return data.decode("utf-8", "replace"), offset + len(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=".build/release/krd")
    ap.add_argument("--pages", type=int, default=3)
    ap.add_argument("--cols", type=int, default=137)
    ap.add_argument("--rows", type=int, default=44)
    ap.add_argument("--cell", default=None, help="forced cell size, passed to krd")
    ap.add_argument("--tag", default="run")
    ap.add_argument("--logdir", default="/tmp")
    ap.add_argument("--settle", type=float, default=2.5, help="seconds to wait for the first paint")
    ap.add_argument("--demo", action="store_true", help="pass --demo (synthetic desk, same encoder)")
    args = ap.parse_args()

    log = os.path.join(args.logdir, "wall-page-step-%s.log" % args.tag)
    if os.path.exists(log):
        os.remove(log)

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.cols, 0, 0))
    argv = [args.binary, "--wall", "--fps", "2", "--log", log, "--debug"]
    if args.demo:
        argv.append("--demo")
    if args.cell:
        argv += ["--cell", args.cell]
    child = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                             preexec_fn=os.setsid, close_fds=True)
    os.close(slave)
    try:
        # The first paint is a full capture of the desk; give ScreenCaptureKit its round-trip.
        first_bytes, _, _ = drain(master, 1.0, args.settle + 20.0)
        frames, offset = read_log(log, 0)
        slots = sorted(set(SLOTW.findall(frames)))
        print(json.dumps({"tag": args.tag, "first_paint_bytes": first_bytes,
                          "slots": [list(s) for s in slots]}))
        # The shelf sits under the stage band; a wheel notch anywhere in it is one page. Aim at the
        # last shelf row so the stage band is never hit whatever the stage's height is.
        row, col = args.rows - 4, max(4, args.cols // 2)
        steps = []
        for i in range(args.pages):
            time.sleep(0.6)
            before, offset = read_log(log, offset)
            t0 = time.monotonic()
            os.write(master, b"\x1b[<65;%d;%dM" % (col, row))   # SGR wheel down
            wire, first, last = drain(master, 0.25, 6.0)
            ms = None if first is None else (last - first) * 1000 + (first - t0) * 0
            ms_total = None if last is None else (last - t0) * 1000
            time.sleep(0.15)
            after, offset = read_log(log, offset)
            payload = PAYLOAD.findall(after)
            reused = REUSED.findall(after)
            paint = PAINT.findall(after)
            rec = {
                "step": i + 1,
                "ms": round(ms_total, 1) if ms_total is not None else None,
                "panel_ms": round(ms, 1) if ms is not None else None,
                "wire_B": wire,
                "payload_B": sum(int(p[3]) for p in payload),
                "panels": len(payload),
                "reused": len(reused),
                "slots": [int(p[0]) for p in payload],
                "reused_slots": [int(s) for s in reused],
                "paint": paint[-1] if paint else None,
                "slots_now": [list(s) for s in sorted(set(SLOTW.findall(after)))],
            }
            steps.append(rec)
            print(json.dumps(rec))
        ok = [s for s in steps if s["ms"] is not None]
        if ok:
            print(json.dumps({
                "tag": args.tag,
                "median_ms": round(statistics.median(s["ms"] for s in ok), 1),
                "median_payload_B": statistics.median(s["payload_B"] for s in ok),
                "median_wire_B": statistics.median(s["wire_B"] for s in ok),
                "median_panels": statistics.median(s["panels"] for s in ok),
                "median_reused": statistics.median(s["reused"] for s in ok),
                "log": log,
            }))
    finally:
        try:
            os.killpg(os.getpgid(child.pid), 9)
        except ProcessLookupError:
            pass
        child.wait()
        os.close(master)


if __name__ == "__main__":
    sys.exit(main() or 0)
