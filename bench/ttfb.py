#!/usr/bin/env python3
"""Time-to-first-picture on the wall, measured from outside the process.

WHY a pty and not a stopwatch: `krd` writes its first paint to the terminal, and the only honest
measurement of "when did the reader see something" is when the bytes reached the pty. This harness
spawns the release binary on a 137x44 pty, timestamps every read, and reports:

  t_text    the first byte of the wall's text paint (placeholders and all)
  t_pic     the first byte of the first picture transmission (`ESC _ G ... a=t`)
  t_pic_all the byte that ends the last picture of the first frame

`--demo` is the safe mode: the pictures are `DemoPicture.render`, no Screen Recording, no window
server, nothing of the reader's desk is touched. What it therefore does NOT include is
ScreenCaptureKit's own latency, which is measured separately (PanelCapture.swift:40) and cannot be
measured here without photographing a real desktop.

Usage: python3 ttfb.py [--runs 5] [--idle 3.0] -- <krd args...>
"""
import os, pty, select, subprocess, sys, time, fcntl, termios, struct, json, statistics

BIN = os.environ.get("KRD_BIN",
                     ".build/release/krd")


def spawn(args, cols=137, rows=44, pixels=None):
    """A pty with a forced window size; no WS_XPIXEL unless `pixels` is given (a terminal that
    reports points, i.e. the ssh case)."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ,
                struct.pack("HHHH", rows, cols,
                            pixels[0] if pixels else 0, pixels[1] if pixels else 0))
    onlcr = termios.tcgetattr(slave)
    onlcr[3] = onlcr[3] & ~termios.ONLCR
    termios.tcsetattr(slave, termios.TCSANOW, onlcr)
    t0 = time.monotonic()
    p = subprocess.Popen([BIN] + args, stdin=slave, stdout=slave, stderr=subprocess.DEVNULL,
                         close_fds=True, preexec_fn=os.setsid)
    os.close(slave)
    return p, master, t0


def measure(args, idle=1.5, cols=137, rows=44, pixels=None):
    p, master, t0 = spawn(args, cols, rows, pixels)
    os.set_blocking(master, False)
    buf = b""
    t_text = t_pic = t_pic_all = None
    pic_seen = 0
    bytes_at_1s = None
    deadline = t0 + 2.5 + idle
    try:
        while time.monotonic() < deadline:
            r, _, _ = select.select([master], [], [], 0.02)
            if r:
                try:
                    chunk = os.read(master, 1 << 16)
                except OSError:
                    break
                now = time.monotonic() - t0
                buf += chunk
                if t_text is None and len(buf) > 0:
                    t_text = now
                if t_pic is None and b"\x1b_G" in buf:
                    t_pic = now
                    pic_seen = buf.count(b"\x1b_G")
                elif t_pic is not None:
                    pic_seen = max(pic_seen, buf.count(b"\x1b_G"))
                if t_pic is not None and t_pic_all is None and now > 0.2:
                    t_pic_all = now
            if bytes_at_1s is None and time.monotonic() - t0 >= 1.0:
                bytes_at_1s = len(buf)
        # idle window: how many bytes did the wall emit while nothing moved?
        idle_bytes = len(buf) - (bytes_at_1s or 0)
        total = len(buf)
    finally:
        try:
            os.killpg(os.getpgid(p.pid), 15)
        except Exception:
            pass
        time.sleep(0.05)
        try:
            os.killpg(os.getpgid(p.pid), 9)
        except Exception:
            pass
        p.wait()
        os.close(master)
    return dict(t_text=t_text, t_pic=t_pic, t_pic_all=t_pic_all, pictures=pic_seen,
                total=total, idle_bytes=idle_bytes)


def main():
    argv = sys.argv[1:]
    runs = 5
    idle = 1.5
    if "--runs" in argv:
        i = argv.index("--runs")
        runs = int(argv[i + 1])
        del argv[i:i + 2]
    if "--idle" in argv:
        i = argv.index("--idle")
        idle = float(argv[i + 1])
        del argv[i:i + 2]
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]

    variants = [
        ("demo, default probes", ["--demo", "--pane", "137x44"]),
        ("demo, both probes answered-away", ["--demo", "--pane", "137x44", "--cell", "8x16",
                                             "--placeholders"]),
        ("demo, --symbols ascii", ["--demo", "--pane", "137x44", "--cell", "8x16",
                                   "--placeholders", "--symbols", "ascii"]),
        ("demo, 100x36", ["--demo", "--pane", "100x36", "--cell", "8x16", "--placeholders"]),
        ("demo, 60x24", ["--demo", "--pane", "60x24", "--cell", "8x16", "--placeholders"]),
    ]
    out = {}
    for label, args in variants:
        rows = []
        for _ in range(runs):
            rows.append(measure(argv + args, idle=idle))
            time.sleep(0.15)
        best = lambda k: min((r[k] for r in rows if r[k] is not None), default=None)
        rec = dict(
            t_text_ms=best("t_text") and round(best("t_text") * 1000, 1),
            t_pic_ms=best("t_pic") and round(best("t_pic") * 1000, 1),
            t_pic_all_ms=best("t_pic_all") and round(best("t_pic_all") * 1000, 1),
            pictures=statistics.median([r["pictures"] for r in rows]),
            total_bytes=int(statistics.median([r["total"] for r in rows])),
            idle_bytes_min=min(r["idle_bytes"] for r in rows),
            idle_bytes_max=max(r["idle_bytes"] for r in rows),
        )
        out[label] = rec
        print(f"{label:36s} {json.dumps(rec)}", flush=True)
    return out


if __name__ == "__main__":
    main()
