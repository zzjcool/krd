#!/usr/bin/env python3
"""30-minute soak: does anything grow while every merged feature is on?

Eleven features landed in one run (keyboard protocol, `--ime`, pid-targeted input, the clipboard
bridge, display-set changes, `--zoom`, backdrop refusal, idle stats, `krd ax`, CI budgets). Each was
tested on its own; this runs the combination for long enough that a per-event leak shows up, and
samples RSS / fds / threads / the `krd ax` state directory every 30 seconds.

    # on the machine being mirrored (the VM), with a release krd beside it:
    python3 probe/soak.py --minutes 30 --binary ./krd-soak

    # shorter run while changing the script:
    python3 probe/soak.py --minutes 2 --interval 10

It prints a markdown table and a verdict, and exits non-zero when a threshold trips. Measurements
are absolute (`ps`, `lsof`, `du`), so the verdict is about *shape*: a flat line, not a number that
has to match a budget.

Why a pty: krd is a terminal application and turns mouse reporting on; with no pty it disables input
and the pointer/zoom paths never run. The master side must be drained continuously -- a full pty
buffer blocks krd's `write(2)`, which looks exactly like the stall this script is meant to detect.
"""
import argparse
import json
import os
import pty
import random
import select
import signal
import subprocess
import sys
import threading
import time

RSS_LIMIT_MB = 10.0        # issue #44's number
FDS_SLACK = 2              # one or two transient descriptors are not a leak
THREAD_SLACK = 2
STATE_LIMIT_MB = 64.0      # 16 snapshots per window, a few hundred KB each
STALL_SECONDS = 5.0        # a bigger gap between stats samples is a stall, not slowness
FREEZE_SECONDS = 60.0      # screen unchanged is not a freeze; `callbacks` not advancing is


def now():
    return time.time()


def sh(*args):
    """Run a command, return stripped stdout ('' on failure). Never raises: a sample that cannot
    be taken is reported as missing rather than killing a 30-minute run."""
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=20)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def rss_mb(pid):
    raw = sh("ps", "-o", "rss=", "-p", str(pid))
    return float(raw) / 1024.0 if raw else None


def fd_count(pid):
    out = sh("lsof", "-p", str(pid))
    return len(out.splitlines()) if out else None


def thread_count(pid):
    out = sh("ps", "-M", "-p", str(pid))
    return len(out.splitlines()) if out else None


def dir_kb(path):
    if not os.path.isdir(path):
        return 0
    return int(sh("du", "-sk", path).split("\t")[0] or 0)


class Drain(threading.Thread):
    """Reads the pty master forever, counting bytes.

    Also counts OSC 52 sequences and `a=t` transmisssions, so "nothing happened" is distinguishable
    from "the test harness swallowed everything".
    """

    def __init__(self, fd):
        super().__init__(daemon=True)
        self.fd = fd
        self.bytes = 0
        self.clipboard = 0
        self.transmits = 0
        self.error = None
        self._stop = threading.Event()

    def run(self):
        tail = b""
        while not self._stop.is_set():
            try:
                ready, _, _ = select.select([self.fd], [], [], 0.5)
            except (OSError, ValueError):
                break
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 1 << 16)
            except OSError:
                break
            if not chunk:
                break
            self.bytes += len(chunk)
            window = tail + chunk
            self.clipboard += window.count(b"\x1b]52;")
            self.transmits += window.count(b"a=t")
            tail = window[-8:]

    def stop(self):
        self._stop.set()


def sgr_mouse(x, y, motion=True, button=3):
    """SGR mouse report: 32 = motion, +3 = no button. krd parses these as pointer moves."""
    code = 32 + button if motion else button
    return "\x1b[<%d;%d;%d%s" % (code, x, y, "M" if motion else "m")


class Stress:
    """The things that happen *to* krd while it runs: clipboard changes, `krd ax` snapshots,
    pointer motion (which is what makes `--zoom-follow` restart the stream)."""

    def __init__(self, args, master, env):
        self.args = args
        self.master = master
        self.env = env
        self.last = {"clipboard": 0.0, "ax": 0.0, "pointer": 0.0}
        self.counts = {"clipboard": 0, "ax": 0, "pointer": 0}
        self.errors = []

    def maybe(self, t):
        if self.args.clipboard_every and t - self.last["clipboard"] >= self.args.clipboard_every:
            self.last["clipboard"] = t
            self.counts["clipboard"] += 1
            # A real pasteboard change in the session krd polls: sized so the OSC 52 payload is
            # realistic (a URL, a paragraph, sometimes 8 KB of text).
            size = random.choice([16, 64, 256, 1024, 8192])
            text = "".join(random.choice("abcdefghijklmnopqrstuvwxyz 0123456789") for _ in range(size))
            result = subprocess.run(["pbcopy"], input=text, text=True, env=self.env)
            if result.returncode != 0:
                self.errors.append("pbcopy exited %d" % result.returncode)
        if self.args.ax_every and t - self.last["ax"] >= self.args.ax_every:
            self.last["ax"] = t
            self.counts["ax"] += 1
            # A separate process on purpose: this is the disk churn the issue asks about
            # (`$TMPDIR/krd-ax`, pruned to 16 snapshots per window).
            result = subprocess.run([self.args.binary, "ax", "tree", "--app", "Finder"],
                                    capture_output=True, text=True, env=self.env, timeout=60)
            if result.returncode not in (0, 5):     # 5 = no Finder window, harmless here
                self.errors.append("krd ax tree exited %d: %s"
                                   % (result.returncode, result.stderr.strip()[:120]))
        if self.args.pointer_every and t - self.last["pointer"] >= self.args.pointer_every:
            self.last["pointer"] = t
            self.counts["pointer"] += 1
            # Corner to corner: with --zoom-follow the pan logic has to restart the stream, which
            # is the path that could leak a stream, a timer or a display callback per pan.
            for x, y in ((2, 2), (self.args.pane[0] - 3, self.args.pane[1] - 3),
                         (self.args.pane[0] // 2, self.args.pane[1] // 2)):
                try:
                    os.write(self.master, sgr_mouse(x, y).encode())
                except OSError as error:
                    self.errors.append("pty write failed: %s" % error)
                    break
                time.sleep(0.4)


def callbacks_frozen(path, quiet_seconds=60.0):
    """Longest run of `--stats-json` samples in which `callbacks` did not advance.

    This is what a dead SCStream looks like from outside: the stats timer keeps writing, `bad`
    stays 0, every memory number stays flat -- and the picture is frozen. The first 30-minute run
    of this script found exactly that (issue #44, `-3805`), so it is a verdict rule now.
    """
    previous_t = previous_callbacks = None
    worst = 0.0
    for raw in open(path if isinstance(path, str) else path, "r"):
        if not raw.endswith("\n"):
            continue
        try:
            sample = json.loads(raw)
        except ValueError:
            continue
        if previous_callbacks is not None and sample["callbacks"] == previous_callbacks:
            worst = max(worst, sample["t"] - previous_t)
        else:
            previous_t = sample["t"]
        previous_callbacks = sample["callbacks"]
    return worst


def stats_gap(path):
    """Biggest gap between consecutive `--stats-json` samples (t is seconds since start).

    A stall is visible here, not in the sampled tails: those are always one `--interval` apart.
    """
    previous = None
    worst = None
    try:
        with open(path, "r") as handle:
            for raw in handle:
                if not raw.endswith("\n"):
                    continue
                try:
                    t = json.loads(raw)["t"]
                except (ValueError, KeyError):
                    continue
                if previous is not None:
                    gap = t - previous
                    worst = gap if worst is None else max(worst, gap)
                previous = t
    except OSError:
        return None
    return worst


def stats_tail(path):
    """Last complete line of the `--stats-json` file, plus the number of lines so far."""
    if not os.path.exists(path):
        return None, 0
    lines = 0
    last = None
    with open(path, "rb") as handle:
        for raw in handle:
            lines += 1
            if raw.endswith(b"\n"):
                last = raw
    if not last:
        return None, lines
    try:
        return json.loads(last), lines - 1
    except ValueError:
        return None, lines - 1


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--minutes", type=float, default=30)
    parser.add_argument("--interval", type=float, default=30, help="sample period, seconds")
    parser.add_argument("--binary", default="./krd", help="krd to run")
    parser.add_argument("--work", default="/tmp/krd-soak", help="state + logs live here")
    parser.add_argument("--pane", default="60x24", help="COLSxROWS, bypasses the pixel-size query")
    parser.add_argument("--cell", default="17x33")
    parser.add_argument("--extra", default="--zoom 2 --zoom-follow --clipboard=in",
                        help="extra krd flags (default: every runtime feature that can be on at once)")
    parser.add_argument("--clipboard-every", type=float, default=60)
    parser.add_argument("--ax-every", type=float, default=120)
    parser.add_argument("--pointer-every", type=float, default=180)
    parser.add_argument("--out", default=None, help="write the sample series as JSON here")
    args = parser.parse_args()

    if not os.access(args.binary, os.X_OK):
        sys.exit("soak: %s is not executable" % args.binary)
    os.makedirs(args.work, exist_ok=True)
    stats_path = os.path.join(args.work, "stats.jsonl")
    log_path = os.path.join(args.work, "krd.log")
    for stale in (stats_path, log_path):
        if os.path.exists(stale):
            os.unlink(stale)

    env = dict(os.environ)
    env["KRD_AX_STATE"] = os.path.join(args.work, "ax")
    env["PATH"] = os.path.dirname(os.path.abspath(args.binary)) + ":" + env.get("PATH", "")

    cols, rows = (int(v) for v in args.pane.split("x"))
    argv = [os.path.abspath(args.binary), "--pane", args.pane, "--cell", args.cell,
            "--stats-json", stats_path, "--log", log_path] + args.extra.split()
    print("# krd %s" % " ".join(argv[1:]))

    pid, master = pty.fork()
    if pid == 0:                                   # child: krd owns the slave
        env["TERM"] = env.get("TERM", "xterm-256color")
        os.execvpe(argv[0], argv, env)
        os._exit(127)

    drain = Drain(master)
    drain.start()
    stress = Stress(argparse.Namespace(**dict(args.__dict__, pane=(cols, rows))), master, env)

    # Wait for the first frame before taking the baseline: a sample taken between fork() and the
    # first `--stats-json` line reads 0.7 MB / 10 fds, and every later sample then looks like a
    # 30 MB "leak". Ten seconds is generous for a 600 ms startup.
    for _ in range(100):
        if stats_tail(stats_path)[0] is not None:
            break
        time.sleep(0.1)
    started = now()
    deadline = started + args.minutes * 60
    samples = [{"t": 0.0, "rss": rss_mb(pid), "fds": fd_count(pid),
                "threads": thread_count(pid), "ax_kb": dir_kb(env["KRD_AX_STATE"]),
                "stats": stats_tail(stats_path)[0], "stats_lines": stats_tail(stats_path)[1]}]
    next_sample = started + args.interval
    interrupted = False
    frozen_since = None
    sample_taken = False

    try:
        while now() < deadline:
            t = now()
            stress.maybe(t)
            if t >= next_sample:
                tail, lines = stats_tail(stats_path)
                live = stats_tail(stats_path)[0]
                # A freeze is only diagnosable while the process is still running: take a stack
                # sample the first time `callbacks` has been still for a minute, and keep going.
                if live is not None:
                    previous = next((x for x in reversed(samples) if x["stats"]), None)
                    if previous is not None and live["callbacks"] == previous["stats"]["callbacks"]:
                        frozen_since = frozen_since or t
                        if not sample_taken and t - frozen_since >= FREEZE_SECONDS:
                            sample_taken = True
                            subprocess.run(["sample", str(pid), "2", "-file",
                                            os.path.join(args.work, "sample.txt")],
                                           capture_output=True)
                            print("# the stream went quiet: stack sample in %s/sample.txt"
                                  % args.work)
                    else:
                        frozen_since = None
                samples.append({"t": round(t - started, 1), "rss": rss_mb(pid),
                                "fds": fd_count(pid), "threads": thread_count(pid),
                                "ax_kb": dir_kb(env["KRD_AX_STATE"]),
                                "stats": tail, "stats_lines": lines,
                "callbacks_at": tail["callbacks"] if tail else None})
                next_sample += args.interval
            time.sleep(1)
    except KeyboardInterrupt:
        interrupted = True

    drain.stop()
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass

    # ---- verdict ---------------------------------------------------------------------------
    warm_window = max(args.interval * 2, 60.0)
    warm = [s for s in samples if s["stats"] is not None and s["t"] <= warm_window]
    if len(warm) < 2:                       # a short run: the baseline is the first good sample
        warm = [s for s in samples if s["stats"] is not None][:1] or samples[:1]
    body = samples[len(warm):] or samples
    short_run = len(samples) < 5

    def peak(key):
        values = [s[key] for s in body if s[key] is not None]
        return max(values) if values else None

    rss0 = max(s["rss"] for s in warm if s["rss"] is not None)
    rss_peak = peak("rss")
    fds0 = max(s["fds"] for s in warm if s["fds"] is not None)
    fds_peak = peak("fds")
    threads0 = max(s["threads"] for s in warm if s["threads"] is not None)
    threads_peak = peak("threads")
    ax_peak_kb = max(s["ax_kb"] for s in samples)

    # A growing *maximum* is the leak signature; a count that moves up and down is normal (SCK
    # worker threads appear and disappear with stream restarts, and a `lsof` sample can catch a
    # transient descriptor). So the second half must not set a new high beyond the slack.
    def late_high(key, slack):
        first = [s[key] for s in body[:max(1, len(body) // 2)] if s[key] is not None]
        late = [s[key] for s in body[max(1, len(body) // 2):] if s[key] is not None]
        if not first or not late:
            return None
        return (max(late) - max(first)) > slack

    fds_late = late_high("fds", FDS_SLACK)
    threads_late = late_high("threads", THREAD_SLACK)

    rss_growth = (rss_peak - rss0) if rss_peak is not None else None
    stall = stats_gap(stats_path)
    frozen = callbacks_frozen(stats_path)
    bad = max((s["stats"]["bad"] for s in samples if s["stats"]), default=0)
    delivered = max((s["stats"]["delivered"] for s in samples if s["stats"]), default=0)

    failures = []
    if rss_growth is None or rss_growth > RSS_LIMIT_MB:
        failures.append("RSS grew %.1f MB (limit %.0f MB)" % (rss_growth or 0, RSS_LIMIT_MB))
    if fds_peak is None:
        failures.append("no fds samples")
    elif fds_late:
        failures.append("fds kept setting new highs: %d -> %d (slack %d)"
                        % (fds0 or 0, fds_peak or 0, FDS_SLACK))
    if threads_peak is None:
        failures.append("no thread samples")
    elif threads_late:
        failures.append("threads kept setting new highs: %d -> %d (slack %d)"
                        % (threads0 or 0, threads_peak or 0, THREAD_SLACK))
    if ax_peak_kb > STATE_LIMIT_MB * 1024:
        failures.append("krd ax state %.1f MB (limit %.0f MB)" % (ax_peak_kb / 1024, STATE_LIMIT_MB))
    if stall is None:
        failures.append("no --stats-json samples: krd never produced a frame")
    elif stall > STALL_SECONDS:
        failures.append("stats gap %.1f s (limit %.0f s)" % (stall, STALL_SECONDS))
    if frozen is not None and frozen > FREEZE_SECONDS:
        failures.append("the capture stream stopped delivering frames for %.0f s "
                        "(limit %.0f s) -- the picture is frozen even though krd is alive"
                        % (frozen, FREEZE_SECONDS))
    if bad and bad > 0:
        failures.append("%d bad frames" % bad)

    # ---- report ----------------------------------------------------------------------------
    print()
    print("| t | RSS | fds | threads | krd ax | stats lines | delivered |")
    print("|---:|---:|---:|---:|---:|---:|---:|")
    step = max(1, len(samples) // 13)
    shown = samples[::step] + [samples[-1]]
    for sample in shown:
        print("| %.0f min | %.1f MB | %s | %s | %d KB | %d | %s |"
              % (sample["t"] / 60, sample["rss"] or 0, sample["fds"], sample["threads"],
                 sample["ax_kb"], sample["stats_lines"],
                 sample["stats"]["delivered"] if sample["stats"] else "-"))
    print()
    print("stress: %d clipboard writes, %d `krd ax` snapshots, %d pointer sweeps; "
          "drained %.1f MB, saw %d OSC 52, %d transmits"
          % (stress.counts["clipboard"], stress.counts["ax"], stress.counts["pointer"],
             drain.bytes / 1e6, drain.clipboard, drain.transmits))
    if stress.errors:
        print("stress errors: %s" % "; ".join(stress.errors[:5]))
    print("RSS %s -> peak %s (%.1f MB), fds %s -> %s, threads %s -> %s, krd ax peak %.1f MB, "
          "max stats gap %s, longest frozen window %s s"
          % (rss0 and round(rss0, 1), rss_peak and round(rss_peak, 1), rss_growth or 0,
             fds0, fds_peak, threads0, threads_peak, ax_peak_kb / 1024,
             stall and round(stall, 1), frozen and round(frozen, 1)))
    if delivered < 10:
        print("note: only %d tiles were ever delivered -- the screen barely changed, so this run "
              "exercised the capture path much less than a busy desktop would" % delivered)
    if short_run:
        print("note: %d samples is too few for a trend; treat the verdict as a smoke test"
              % len(samples))
    if interrupted:
        print("interrupted: the run did not reach its planned duration")
        failures.append("interrupted")
    print()
    print("VERDICT: %s" % ("FAIL - " + "; ".join(failures) if failures else "PASS"))

    if args.out:
        with open(args.out, "w") as handle:
            json.dump({"argv": argv, "minutes": args.minutes, "interval": args.interval,
                       "samples": samples, "stress": stress.counts, "stress_errors": stress.errors,
                       "drain_bytes": drain.bytes, "osc52": drain.clipboard,
                       "transmits": drain.transmits, "rss_growth_mb": rss_growth,
                       "fds": [fds0, fds_peak], "threads": [threads0, threads_peak],
                       "ax_peak_kb": ax_peak_kb, "stall": stall, "frozen": frozen, "bad": bad,
                       "delivered": delivered, "failures": failures},
                      handle, indent=1)
        print("json: %s" % args.out)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
