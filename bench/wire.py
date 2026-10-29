#!/usr/bin/env python3
"""L2: krd under a pty against a rate-limited drain.

The one thing the encoder benchmark cannot see is the write path. `write(2)` on a pty
blocks when the reader is behind, and that is what a real terminal does. This harness is
the other end: it drains the master side at a chosen rate (or as fast as possible) and
reports what krd experienced, from krd's own per-frame JSON on stderr.

    python3 bench/wire.py --case line --seconds 6 --drain 0    -- krd --bench-wire line
    python3 bench/wire.py --case line --seconds 6 --drain 5MB  -- krd --bench-wire line
    python3 bench/wire.py --case none --seconds 3 --drain 0 --assert-zero-bytes -- krd ...

Output: one JSON object on stdout. Nothing is asserted here except with --assert-zero-bytes;
budget verdicts belong to bench/bench.py, which knows the whole run.
"""
import argparse
import json
import os
import pty
import re
import select
import statistics
import subprocess
import sys
import tempfile
import time

CHUNK = 16384


def parse_rate(text):
    """'5MB' -> bytes/s, '0' -> unlimited."""
    if not text:
        return 0.0
    match = re.match(r"^\s*([\d.]+)\s*([kKmMgG]?)[bB]?(/s)?\s*$", text)
    if not match:
        raise argparse.ArgumentTypeError("expected 0, 512K, 5MB (per second)")
    value = float(match.group(1))
    unit = match.group(2).lower()
    return value * {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[unit]


def percentile(values, q):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round((len(ordered) - 1) * q)))
    return ordered[index]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", default="line")
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--drain", type=parse_rate, default=0.0,
                    help="bytes/s the fake terminal accepts; 0 = unlimited")
    ap.add_argument("--assert-zero-bytes", action="store_true",
                    help="fail unless nothing was written after the first frame")
    ap.add_argument("--out", help="also write the result JSON here")
    ap.add_argument("command", nargs=argparse.REMAINDER,
                    help="-- krd --bench-wire <case> ...")
    args = ap.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        ap.error("no command: pass -- krd --bench-wire <case>")

    stderr_file = tempfile.NamedTemporaryFile(prefix="krd-wire-", suffix=".jsonl", delete=False)
    master, slave = pty.openpty()
    started = time.time()
    proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=slave,
                            stderr=stderr_file, close_fds=True)
    os.close(slave)

    total = 0
    first_frame_bytes = None
    marks = []          # (t, bytes_after) to compute the achieved rate over time
    drain = args.drain
    try:
        while True:
            if proc.poll() is not None:
                # drain whatever is already buffered, then stop
                if not select.select([master], [], [], 0.05)[0]:
                    break
            ready, _, _ = select.select([master], [], [], 0.5)
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
            total += len(chunk)
            if first_frame_bytes is None:
                first_frame_bytes = total
            marks.append((time.time(), total))
            if drain > 0:
                elapsed = time.time() - started
                allowed = drain * elapsed
                if total > allowed:
                    time.sleep(min(0.25, (total - allowed) / drain))
    finally:
        if proc.poll() is None:
            proc.wait(timeout=10)
        os.close(master)

    wall = time.time() - started
    stderr_file.close()
    with open(stderr_file.name) as handle:
        lines = handle.read().splitlines()
    os.unlink(stderr_file.name)

    frames, summary, noise = [], None, []
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            if line:
                noise.append(line)
            continue
        try:
            object = json.loads(line)
        except json.JSONDecodeError:
            noise.append(line)
            continue
        if "wire" in object:
            summary = object["wire"]
        elif "frame" in object:
            frames.append(object)

    result = {
        "case": args.case,
        "drain_bps": drain,
        "seconds": round(wall, 3),
        "bytes": total,
        "mbps": round(total / 1048576 / wall, 2) if wall > 0 else 0,
        "frames": len(frames),
        "exit_code": proc.returncode,
        "summary": summary,
        "noise": noise[-5:],
    }
    if frames:
        write_ms = [f["write_ms"] for f in frames]
        pipe_ms = [f["pipe_ms"] for f in frames]
        compress_ms = [f["compress_ms"] for f in frames]
        result["write_ms"] = {
            "p50": round(statistics.median(write_ms), 2),
            "p99": round(percentile(write_ms, 0.99), 2),
            "max": round(max(write_ms), 2),
            "over5": sum(1 for ms in write_ms if ms > 5),
        }
        result["pipe_ms"] = {
            "p50": round(statistics.median(pipe_ms), 2),
            "p99": round(percentile(pipe_ms, 0.99), 2),
            "max": round(max(pipe_ms), 2),
        }
        result["compress_ms"] = {"p50": round(statistics.median(compress_ms), 2)}
        result["late"] = sum(1 for f in frames if f["pipe_ms"] > 50)
        result["tiles"] = sum(f["tiles"] for f in frames)
        # bytes after the first frame: the static-screen invariant
        result["bytes_after_first_frame"] = total - (first_frame_bytes or total)

    text = json.dumps(result, indent=2)
    print(text)
    if args.out:
        with open(args.out, "w") as handle:
            handle.write(text + "\n")

    if args.assert_zero_bytes and result["bytes_after_first_frame"] > 0:
        print("FAIL: %d bytes written after the first frame (static screen must be free)"
              % result["bytes_after_first_frame"], file=sys.stderr)
        return 1
    if proc.returncode != 0:
        print("FAIL: krd exited %s; stderr: %s" % (proc.returncode, " | ".join(result["noise"])),
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
