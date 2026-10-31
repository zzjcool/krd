#!/usr/bin/env python3
"""Time to first paint / first picture for a `krd` process on a pty that answers nothing.

Issue #99: the wall used to spend 1.7 s on three serial terminal probes before its first byte.
This is the number that says whether it still does, measured the only way that cannot lie about
it: the *bytes on the pty* and the moment they arrived.

    python3 bench/ttfb.py --runs 5 --idle 1.5 -- --demo --pane 137x44
    python3 bench/ttfb.py --runs 5 --idle 1.5 -- --demo --pane 137x44 --cell 8x16 --placeholders

The pty is 137x44 (the size in the issue) and it never answers `CSI 16t`/`CSI 14t` or the kitty
`U=1` probe — i.e. exactly the `Terminal.app`/tmux-without-passthrough/ssh case. `--cell` and
`--placeholders` are passed through to krd when given, so the "answered" pair is reproducible too.

What is reported, per run and as a median:

    first byte        the process wrote *something* (alternate screen, clear)
    first text        the first `ESC[<row>;<col>H` — the wall's own text paint
    first picture     the first kitty graphics APC that is not the probe (`i=31`)
    wall complete     the last graphics APC before the pane went idle

No window server, no screen recording grant, no window is touched: `--demo` draws synthetic
pictures, so a bench run on a busy machine measures krd and not the desktop.
"""
import argparse
import os
import pty
import re
import select
import signal
import statistics
import struct
import sys
import termios
import time
import fcntl

COLS, ROWS = 137, 44
# The probe's image id, from `TermGeometry.PlaceholderProbe`. Anything else carrying `a=t` is a
# picture. Hard-coded on purpose: this script is a ruler, it must not import the code it measures.
PROBE_IMAGE = b"i=31"
CURSOR_HOME = re.compile(rb"\x1b\[(\d+);(\d+)H")


def run_once(argv, idle, max_seconds):
    started = time.monotonic()
    pid, fd = pty.fork()
    if pid == 0:                                    # child
        os.execv(argv[0], argv)
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    timeline = []                                   # (t_ms, label, payload)
    buffer = b""
    first_byte = first_text = first_picture = None
    last_picture = None
    killed = False
    try:
        while True:
            now = time.monotonic()
            elapsed = now - started
            if elapsed > max_seconds:
                killed = True
                break
            timeout = min(idle, max_seconds - elapsed)
            ready, _, _ = select.select([fd], [], [], timeout)
            if not ready:
                break                               # idle: the wall has finished its first frame
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            t = (time.monotonic() - started) * 1000.0
            if first_byte is None:
                first_byte = t
            buffer += chunk
            # Split graphics APCs out of the stream so a picture's arrival is its own timestamp.
            while True:
                start = buffer.find(b"\x1b_G")
                home = CURSOR_HOME.search(buffer)
                if start < 0 and home is None:
                    break
                if start >= 0 and (home is None or start < home.start()):
                    end = buffer.find(b"\x1b\\", start)
                    if end < 0:
                        break                        # partial APC: wait for the rest
                    body = buffer[start + 3:end]
                    buffer = buffer[end + 2:]
                    if body.startswith(b"a=d"):
                        # a delete (`d=a` clears the session, `d=i` is the probe's own cleanup):
                        # it moves no picture and must not be anyone's "first picture".
                        timeline.append((t, "clear", body[:40]))
                    elif PROBE_IMAGE in body:
                        timeline.append((t, "probe", body[:40]))
                    else:
                        if first_picture is None:
                            first_picture = t
                        last_picture = t
                        timeline.append((t, "picture", body[:40]))
                else:
                    if first_text is None:
                        first_text = t
                    timeline.append((t, "text", home.group(0)))
                    buffer = buffer[home.end():]
    finally:
        try:
            os.kill(pid, signal.SIGKILL)             # SIGKILL: a wall has a SIGTERM cleanup that
            os.waitpid(pid, 0)                       # writes to the pane; we want none of it
        except ProcessLookupError:
            pass
        os.close(fd)

    def ms(v):
        return None if v is None else round(v, 1)

    return {
        "first_byte": ms(first_byte),
        "first_text": ms(first_text),
        "first_picture": ms(first_picture),
        "wall_complete": ms(last_picture),
        "probes": sum(1 for e in timeline if e[1] == "probe"),
        "clears": sum(1 for e in timeline if e[1] == "clear"),
        "pictures": sum(1 for e in timeline if e[1] == "picture"),
        "killed": killed,
        "trace": timeline[:6] + ([("...", "", "")] if len(timeline) > 6 else []),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--idle", type=float, default=1.5,
                    help="stop a run after this many seconds of silence (default 1.5)")
    ap.add_argument("--max", type=float, default=15.0, help="hard cap per run (default 15 s)")
    ap.add_argument("--trace", action="store_true", help="print every run's first events")
    ap.add_argument("--binary", default=".build/release/krd")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    extra = [a for a in args.cmd if a != "--"]
    argv = [args.binary] + extra
    if not os.path.exists(argv[0]):
        sys.exit(f"no binary at {argv[0]} - swift build -c release first")

    print(f"cmd: {' '.join(argv)}   pty {COLS}x{ROWS}   runs {args.runs}\n")
    keys = ["first_byte", "first_text", "first_picture", "wall_complete"]
    results = []
    for i in range(args.runs):
        r = run_once(argv, args.idle, args.max)
        results.append(r)
        print(f"run {i + 1}: " + "  ".join(f"{k}={r[k]} ms" for k in keys)
              + f"  probes={r['probes']} pictures={r['pictures']}"
              + ("  KILLED" if r["killed"] else ""))
        if args.trace:
            for t, label, payload in r["trace"]:
                print(f"    t={t} {label} {payload!r}")
    print("\nmedian of " + str(len(results)) + ":")
    for k in keys:
        vals = [r[k] for r in results if r[k] is not None]
        print(f"  {k:14s} {round(statistics.median(vals), 1) if vals else None} ms"
              f"   (min {min(vals) if vals else None})")


if __name__ == "__main__":
    main()
