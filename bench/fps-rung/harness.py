#!/usr/bin/env python3
"""L2: the 15 fps rung of `--quality auto`, measured against a real pty.

`QualityGovernor` steps its ladder 80/20 -> 70/20 -> 50/20 -> 50/15 -> 50/10 when the *write*
side is behind, and `Scene.handleFrame` enforces the frame-rate rungs with

    if options.qualityAuto, effectiveFps < options.fps {
        let due = 1000.0 / Double(max(effectiveFps, 1))
        if started - lastDrawAt < due - 1 { return }        // Sources/krd/main.swift:2570-2573
        lastDrawAt = started
    }

`lastDrawAt` is the last frame that *drew*, so the gate measures "a whole period since I last drew"
rather than "am I owed a frame": a source at a fixed 50 ms cadence (`--fps 20`, the default) cannot
reach the 66.67 ms rung -- every second frame is dropped and the rung delivers 10 fps.

This harness is the other end of the pty. It runs a real `krd --mock --dev` under a pty and drains
the master at a chosen rate (or as fast as possible), which is what a slow link looks like from
inside krd: `write(2)` blocks, `write_ms` exceeds `1000/fps`, the governor calls the frames late and
walks the ladder. The rung changes come from krd's own log (`--log`), the frame counts from its own
`--stats-json`, so nothing here has to guess what krd thinks it is doing:

    t        seconds since the session started (stats ndjson)
    tiles_total  frames the loop drew, cumulative -- i.e. *after* the gate (framesHandled)
    fps      drawn frames / second over the interval, as krd computes it
    write_ms last write's blocking time -- the number the governor reads

Usage:

    # the bug: a link too slow for 20 fps, so the ladder steps to 15 (and then 10)
    python3 bench/fps-rung/harness.py --label slow --fps 20 --quality auto \\
        --drain-bytes 1024 --tick-ms 50 --seconds 70

    # control A: the same drain, no ladder -- what the link itself sustains at 20 fps
    python3 bench/fps-rung/harness.py --label pinned20 --fps 20 --quality 80 \\
        --drain-bytes 1024 --tick-ms 50 --seconds 30

    # control B: the same drain at 15 fps, pinned -- shows 15 fps *is* deliverable on this link
    python3 bench/fps-rung/harness.py --label pinned15 --fps 15 --quality 80 \\
        --drain-bytes 1024 --tick-ms 50 --seconds 30

    # control C: fast drain, no governor pressure -- the un-governed baseline
    python3 bench/fps-rung/harness.py --label fast --fps 20 --quality auto \\
        --drain-bytes 0 --seconds 20

Output: one JSON object on stdout (and `--json <path>`), written by `report()`. Nothing is asserted
here; the numbers go in RESULTS.md.
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
import tempfile
import termios
import time

# `krd: pipe is behind; quality 50, 20 fps -> quality 50, 15 fps` -- QualityGovernor.Change.line
CHANGE = re.compile(r"krd: (pipe is behind|pipe has headroom); quality (\d+), (\d+) fps -> "
                    r"quality (\d+), (\d+) fps")
CHUNK = 65536
# One paced read per tick; a tick that reads nothing is still a tick, so the rate is a hard ceiling
# and not an average a burst can catch up on.
TICK_DEFAULT_MS = 50


def parse_size(text):
    m = re.match(r"^(\d+)x(\d+)$", text or "")
    if not m:
        raise argparse.ArgumentTypeError("expected WxH, e.g. 120x40")
    return int(m.group(1)), int(m.group(2))


def median(values):
    if not values:
        return None
    ordered = sorted(values)
    n = len(ordered)
    return ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2


def mean(values):
    return sum(values) / len(values) if values else None


def round_all(value, digits=2):
    if isinstance(value, float):
        return round(value, digits)
    if isinstance(value, list):
        return [round_all(v, digits) for v in value]
    if isinstance(value, dict):
        return {k: round_all(v, digits) for k, v in value.items()}
    return value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--krd", default=os.path.join(os.path.dirname(__file__), "..", "..",
                                                  ".build", "release", "krd"))
    ap.add_argument("--label", default="run")
    ap.add_argument("--fps", type=int, default=20, help="--fps: the capture cadence")
    ap.add_argument("--quality", default="auto",
                    help="auto = the ladder under test; 80 = pinned, the gate is off")
    ap.add_argument("--drain-bytes", type=int, default=1024,
                    help="bytes the fake terminal takes per tick; 0 = as fast as possible")
    ap.add_argument("--tick-ms", type=float, default=TICK_DEFAULT_MS,
                    help="how often a paced drain reads (default 50 ms)")
    ap.add_argument("--seconds", type=float, default=70.0, help="wall time before SIGTERM")
    ap.add_argument("--pane", type=parse_size, default=(120, 40), help="pane the mock draws into")
    ap.add_argument("--xpixel", type=int, default=1200)
    ap.add_argument("--ypixel", type=int, default=800)
    ap.add_argument("--dev", dest="dev", action="store_true", default=True)
    ap.add_argument("--no-dev", dest="dev", action="store_false")
    ap.add_argument("--json", help="also write the report here")
    ap.add_argument("--keep", action="store_true", help="keep the log/stats files")
    args = ap.parse_args()
    args.krd = os.path.abspath(args.krd)

    workdir = tempfile.mkdtemp(prefix="krd-fps-rung-")
    stats_path = os.path.join(workdir, "stats.ndjson")
    log_path = os.path.join(workdir, "krd.log")
    stderr_path = os.path.join(workdir, "stderr.txt")

    command = [args.krd, "--mock", "--fps", str(args.fps),
               "--pane", "%dx%d" % args.pane,
               "--stats-json", stats_path, "--log", log_path]
    if args.dev:
        command.append("--dev")
    if args.quality != "auto":
        command += ["--quality", args.quality]

    master, slave = pty.openpty()
    # A terminal that reports its grid: 120x40 cells of 10x20 px, so the mock's frame size and the
    # tile grid are fixed and two runs are the same picture.
    fcntl.ioctl(slave, termios.TIOCSWINSZ,
                struct.pack("HHHH", args.pane[1], args.pane[0], args.ypixel, args.xpixel))

    env = dict(os.environ)
    env.setdefault("TERM", "xterm-256color")
    env.pop("KITTY_WINDOW_ID", None)          # keep the transport the plain per-tile one
    stderr_file = open(stderr_path, "wb")
    started = time.monotonic()
    proc = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=stderr_file,
                            close_fds=True, env=env)
    os.close(slave)

    reads_per_second = 1000.0 / args.tick_ms
    drain_per_second = args.drain_bytes * reads_per_second if args.drain_bytes else 0
    total_bytes = 0
    byte_marks = []                            # (t, bytes) per tick, for the drained MB/s
    changes = []                               # (t, from, to, reason), read live from --log
    log_offset = 0

    def read_new_log():
        nonlocal log_offset
        try:
            with open(log_path, "rb") as handle:
                handle.seek(log_offset)
                fresh = handle.read()
        except FileNotFoundError:
            return
        if not fresh:
            return
        log_offset += len(fresh)
        for line in fresh.decode("utf-8", "replace").splitlines():
            m = CHANGE.search(line)
            if m:
                reason, q0, f0, q1, f1 = m.groups()
                changes.append((round(time.monotonic() - started, 3),
                                (int(q0), int(f0)), (int(q1), int(f1)), reason))

    deadline = started + args.seconds
    next_tick = time.monotonic()
    try:
        while time.monotonic() < deadline:
            # Pace *before* reading: a tick hands the terminal at most one allowance. Sleeping here
            # rather than waiting in `select` is the difference between a 20 KB/s ceiling and a
            # busy loop -- `select` returns at once whenever the pty has data, which it always does
            # while krd is drawing.
            delay = next_tick - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            allowance = args.drain_bytes if args.drain_bytes else CHUNK
            taken = 0
            while taken < allowance:
                ready, _, _ = select.select([master], [], [], 0)
                if not ready:
                    break
                try:
                    chunk = os.read(master, min(allowance - taken, CHUNK))
                except OSError:
                    chunk = b""
                if not chunk:
                    break
                taken += len(chunk)
                total_bytes += len(chunk)
            byte_marks.append((time.monotonic() - started, total_bytes))
            read_new_log()
            next_tick += args.tick_ms / 1000.0
            if next_tick < time.monotonic() - 1.0:      # a stalled tick must not burst after
                next_tick = time.monotonic()
    finally:
        read_new_log()
    wall = time.monotonic() - started

    # Let it exit the way a real session ends, then take the last bytes off the wire.
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
    drain_until = time.monotonic() + 5.0
    while time.monotonic() < drain_until:
        ready, _, _ = select.select([master], [], [], 0.05)
        if not ready:
            if proc.poll() is not None:
                break
            continue
        try:
            chunk = os.read(master, CHUNK)
        except OSError:
            break
        if not chunk:
            break
        total_bytes += len(chunk)
    try:
        exit_code = proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        exit_code = -9
    os.close(master)
    stderr_file.close()

    rows = []
    with open(stats_path, "r", errors="replace") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            rows.append(row)

    # Delivered fps per stats interval, straight from the cumulative drawn-frame counter: the JSON's
    # own `fps` is the same rate from the same counters, kept as `fps_json` only to show they agree.
    intervals = []
    for before, now in zip(rows, rows[1:]):
        dt = now["t"] - before["t"]
        if dt <= 0.2:
            continue
        intervals.append({
            "t": (before["t"] + now["t"]) / 2,
            "fps": (now["tiles_total"] - before["tiles_total"]) / dt,
            "fps_json": now["fps"],
            "write_ms": now["write_ms"],
            "quality": now["quality"],
            "mbps": now["mbps"],
        })

    def window(lo, hi):
        picked = [i for i in intervals if lo <= i["t"] <= hi]
        if not picked:
            return None
        return {
            "intervals": len(picked),
            "fps_median": round(median([i["fps"] for i in picked]), 2),
            "fps_mean": round(mean([i["fps"] for i in picked]), 2),
            "fps_min": round(min(i["fps"] for i in picked), 2),
            "fps_max": round(max(i["fps"] for i in picked), 2),
            "fps_json_median": round(median([i["fps_json"] for i in picked]), 2),
            "write_ms_p50": round(median([i["write_ms"] for i in picked]), 2),
            "mbps_p50": round(median([i["mbps"] for i in picked]), 3),
            "quality": sorted({i["quality"] for i in picked}),
        }

    # The windows: the last quiet stretch *before* the first change of any kind, and the stretch at
    # each frame-rate rung afterwards. A rung's window stops where the *next* change starts (a
    # quality step or an upgrade back up), so neither can flatter it.
    marks = [c[0] for c in changes]
    first_change_at = marks[0] if marks else wall
    rate_changes = [c for c in changes if c[1][1] != c[2][1]]
    rungs = []
    for index, (at, before, after, reason) in enumerate(rate_changes):
        later = [m for m in marks if m > at]
        end = later[0] if later else wall
        # skip the first two seconds after a change: the rung is applied on the main queue, and the
        # stats interval that straddles it is half one rung and half the other
        rungs.append({
            "at_s": at,
            "from": "%d fps, q%d" % (before[1], before[0]),
            "to": "%d fps, q%d" % (after[1], after[0]),
            "window": window(at + 2.0, max(at + 2.5, end - 0.5)),
            "delivered_ratio_of_rung": None,
        })
        entry = rungs[-1]
        if entry["window"]:
            entry["delivered_ratio_of_rung"] = round(entry["window"]["fps_median"] / after[1], 3)

    baseline = window(max(1.0, first_change_at - 12.0), max(2.0, first_change_at - 1.0))
    at_15 = next((r for r in rungs if r["to"].startswith("15 fps")), None)
    at_10 = next((r for r in rungs if r["to"].startswith("10 fps")), None)
    final = window(max(3.0, wall - 12.0), wall - 1.0)

    # pty throughput over the whole run, and over the run's last five seconds
    drained = None
    if len(byte_marks) > 1:
        span = byte_marks[-1][0] - byte_marks[0][0]
        drained = round(total_bytes / span / 1024.0, 1) if span > 0 else None   # KB/s

    report = {
        "label": args.label,
        "command": " ".join(command),
        "fps_flag": args.fps,
        "quality": args.quality,
        "drain_bytes_per_tick": args.drain_bytes,
        "tick_ms": args.tick_ms,
        "drain_kbps_ceiling": round(drain_per_second / 1024.0, 1) if drain_per_second else None,
        "drain_kbps_measured": drained,
        "seconds": round(wall, 2),
        "exit_code": exit_code,
        "changes": [{"at_s": c[0], "from": "%d fps, q%d" % (c[1][1], c[1][0]),
                     "to": "%d fps, q%d" % (c[2][1], c[2][0]), "reason": c[3]} for c in changes],
        "baseline_before_first_step": baseline,
        "rungs": rungs,
        "final_window": final,
        "at_15fps_rung": at_15,
        "at_10fps_rung": at_10,
        "ideal_15": 15,
        "note": ("fps = frames drawn per second, from the stats' cumulative tiles_total -- "
                 "i.e. after the frame-rate gate; write_ms is the blocking write the governor reads"),
        "files": {"log": log_path, "stats": stats_path, "stderr": stderr_path},
    }
    if not args.keep:
        pass    # the files stay in /tmp; the report quotes everything that matters
    text = json.dumps(round_all(report), indent=2)
    print(text)
    if args.json:
        with open(args.json, "w") as handle:
            handle.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
