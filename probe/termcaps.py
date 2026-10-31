#!/usr/bin/env python3
"""Ask the terminal what it can do, and time what asking costs (docs/design-ui-v2.zh-CN.md §2).

    python3 probe/termcaps.py --json /tmp/caps.json        # in the terminal you want to know about
    scp probe/termcaps.py mac:/tmp/ && ssh -t mac python3 /tmp/termcaps.py --json /tmp/caps.json
    python3 probe/termcaps.py --report /tmp/caps.json      # print a saved run (no tty needed)

Every query is followed by DA1 (CSI c), which every VT terminal answers: whatever arrives before
that answer belongs to the query, so a terminal that ignores a query costs one round trip instead
of a timeout. Runs on the alternate screen and switches off every mode it switched on.

Sections: identity, graphics (a=q, U=1, animation frames), keyboard, sizes, colours, DECRQM, the
reports 2033/2048 send the moment they are enabled, text widths with and without mode 2027, REP,
and latency: the DSR round trip, and 20 queries asked one by one vs in one write - the number that
decides how krd should probe at startup.
"""
import base64
import json
import os
import re
import select
import sys
import termios
import time
import tty

DA1 = re.compile(rb"\x1b\[\?[\d;]*c")
ST = "\x1b\\"

GLYPHS = [
    ("U+25B2 up triangle", "\u25b2"),
    ("U+25A3 window", "\u25a3"),
    ("U+2922 expand", "\u2922"),
    ("U+1F5A5 display", "\U0001f5a5"),
    ("U+1F5A5 + VS16", "\U0001f5a5\ufe0f"),
    ("U+2630 trigram (menu)", "\u2630"),
    ("U+2699 gear", "\u2699"),
    ("U+2699 + VS16", "\u2699\ufe0f"),
    ("U+2764 + VS16 heart", "\u2764\ufe0f"),
    ("U+1F44D + skin tone", "\U0001f44d\U0001f3fd"),
    ("ZWJ family", "\U0001f468\u200d\U0001f469\u200d\U0001f467"),
    ("flag CN", "\U0001f1e8\U0001f1f3"),
    ("CJK hiragana", "\u3042"),
    ("powerline U+E0B6", "\ue0b6"),
    ("nerd U+F015 home", "\uf015"),
    ("nerd U+F0379 monitor", "\U000f0379"),
    ("octant U+1CD00", "\U0001cd00"),
    ("eighth block U+258F", "\u258f"),
    ("ellipsis U+2026", "\u2026"),
    # Every other glyph krd draws today (WallSymbols, Chrome, LoadingView) or plans to (design-ui-v2 §4).
    ("U+25AA small square", "\u25aa"),
    ("U+25BC down triangle", "\u25bc"),
    ("U+2B05 left arrow", "\u2b05"),
    ("U+00B7 middle dot", "\u00b7"),
    ("U+00D7 times", "\u00d7"),
    ("U+2014 em dash", "\u2014"),
    ("U+2013 en dash", "\u2013"),
    ("U+25CF black circle", "\u25cf"),
    ("U+2195 up-down arrow", "\u2195"),
    ("U+2192 right arrow", "\u2192"),
    ("U+256D rounded corner", "\u256d"),
    ("U+2580 upper half block", "\u2580"),
    ("U+2921 shrink", "\u2921"),
    ("U+25B8 small triangle", "\u25b8"),
    ("U+21BA reload", "\u21ba"),
]

MODES = [1000, 1002, 1003, 1004, 1006, 1016, 2004, 2026, 2027, 2031, 2033, 2048]

# The 20 queries timed one by one and then in a single write.
BATCH = ["\x1b[>c", "\x1b[>0q", "\x1b[?u", "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA" + ST,
         "\x1b[16t", "\x1b[14t", "\x1b[18t", "\x1b]10;?" + ST, "\x1b]11;?" + ST, "\x1b[?996n"] + \
        ["\x1b[?%d$p" % m for m in (1004, 1006, 1016, 2004, 2026, 2027, 2031, 2033, 2048)] + \
        ["\x1b[5n"]


class Tty:
    def __init__(self):
        self.fd = os.open("/dev/tty", os.O_RDWR)
        self.saved = termios.tcgetattr(self.fd)
        # DEC modes this run toggles, with their DECRQM state from before (1 set, 2 reset, None unknown).
        self.touched = {}
        tty.setraw(self.fd)

    def write(self, s):
        data = s.encode("utf-8") if isinstance(s, str) else s
        while data:
            data = data[os.write(self.fd, data):]

    def read_until(self, done, timeout):
        buf = b""
        end = time.time() + timeout
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], max(0.0, end - time.time()))
            if not ready:
                break
            buf += os.read(self.fd, 65536)
            if done(buf):
                break
        return buf

    def ask(self, query, timeout=2.0):
        """(reply without the DA1 sentinel, milliseconds, answered)"""
        t0 = time.perf_counter()
        self.write(query + "\x1b[c")
        buf = self.read_until(lambda b: DA1.search(b) is not None, timeout)
        ms = (time.perf_counter() - t0) * 1000
        hits = list(DA1.finditer(buf))
        if not hits:
            return buf.decode("latin-1"), ms, False
        last = hits[-1]
        return (buf[:last.start()] + buf[last.end():]).decode("latin-1"), ms, True

    def reply(self, query):
        return self.ask(query)[0]

    def column_after(self, text):
        """0-based cursor column after printing `text` at column 0 (CPR)."""
        m = re.search(r"\x1b\[(\d+);(\d+)R", self.reply("\x1b[H\x1b[2K" + text + "\x1b[6n"))
        return int(m.group(2)) - 1 if m else None

    def restore(self):
        termios.tcsetattr(self.fd, termios.TCSAFLUSH, self.saved)

    def restore_modes(self, modes):
        """The escapes that put `modes` back as DECRQM found them. Unknown means reset, the default."""
        return "".join("\x1b[?%d%s" % (m, "h" if self.touched.get(m) in (1, 3) else "l") for m in modes)


def rgb1(n):
    return base64.b64encode(bytes(n)).decode()


def measure(t):
    res = {}
    # DA1 is the sentinel every other query is closed with, so its own answer is read raw here.
    t.write("\x1b[c")
    first = DA1.search(t.read_until(lambda b: DA1.search(b) is not None, 3.0))
    res["DA1"] = first.group(0).decode("latin-1") if first else ""
    if not first:
        res["error"] = "no answer to DA1 within 3 s: nothing else can be measured here"
        return res

    # identity
    res["DA2"] = t.reply("\x1b[>c")
    res["XTVERSION"] = t.reply("\x1b[>0q")
    res["XTGETTCAP TN"] = t.reply("\x1bP+q544e" + ST)

    # graphics
    res["kitty a=q"] = t.reply("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA" + ST)
    res["kitty U=1"] = t.reply("\x1b_Ga=t,i=4243,f=24,s=1,v=1,q=0;" + rgb1(3) + ST +
                               "\x1b_Ga=p,i=4243,p=1,U=1,c=1,r=1,q=0" + ST)
    res["kitty a=f frame"] = t.reply("\x1b_Ga=t,i=4242,f=24,s=2,v=2,q=2;" + rgb1(12) + ST +
                                     "\x1b_Ga=f,i=4242,f=24,s=2,v=2,z=110,q=0;" + rgb1(12) + ST)
    t.write("\x1b_Ga=d,d=I,i=4242,q=2" + ST + "\x1b_Ga=d,d=I,i=4243,q=2" + ST)

    # keyboard
    res["kitty keyboard"] = t.reply("\x1b[?u")
    res["kitty keyboard push 11"] = t.reply("\x1b[>11u\x1b[?u\x1b[<u")

    # sizes and colours
    for name, q in [("CSI 16t cell px", "\x1b[16t"), ("CSI 14t text px", "\x1b[14t"),
                    ("CSI 18t cells", "\x1b[18t"), ("OSC 10 fg", "\x1b]10;?" + ST),
                    ("OSC 11 bg", "\x1b]11;?" + ST), ("OSC 12 cursor", "\x1b]12;?" + ST),
                    ("OSC 4;1 red", "\x1b]4;1;?" + ST), ("CSI ?996n scheme", "\x1b[?996n")]:
        res[name] = t.reply(q)

    # modes: 0 unknown, 1 set, 2 reset, 3 permanently set, 4 permanently reset
    modes = {}
    for m in MODES:
        mm = re.search(r"\x1b\[\?(\d+);(\d)\$y", t.reply("\x1b[?%d$p" % m))
        modes[str(m)] = int(mm.group(2)) if mm else None
    res["DECRQM"] = modes

    # what a report mode sends the moment it is switched on (both start reset; put back what was)
    t.touched.update({m: modes.get(str(m)) for m in (2027, 2033, 2048)})
    res["?2033h report"] = t.reply("\x1b[?2033h")
    res["?2048h report"] = t.reply("\x1b[?2048h")
    t.write(t.restore_modes((2033, 2048)))

    # styled underline, text sizing, REP
    res["SGR 4:3 via DECRQSS"] = t.reply("\x1b[4:3m\x1bP$qm" + ST + "\x1b[0m")
    res["OSC 66 w=2 column"] = t.column_after("\x1b]66;w=2; \x07")
    res["REP column (1 + 9b)"] = t.column_after("\u2500\x1b[9b")

    # widths, as the cursor moves - with grapheme clustering explicitly off, then on. Ghostty
    # starts with 2027 set and Rex with it reset, so "the terminal's default" is neither column.
    t.write("\x1b[?2027l")
    res["width"] = {label: t.column_after(g) for label, g in GLYPHS}
    t.write("\x1b[?2027h")
    res["width 2027"] = {label: t.column_after(g) for label, g in GLYPHS}
    t.write(t.restore_modes((2027,)) + "\x1b[H\x1b[2K")

    # latency: DSR round trips, off the 20 ms grid ssh sends keystrokes on. Drain first: a late
    # answer from above must not be taken for one of these.
    t.read_until(lambda b: False, 0.3)
    rtt = []
    for _ in range(40):
        t0 = time.perf_counter()
        t.write("\x1b[5n")
        t.read_until(lambda b: b"\x1b[0n" in b, 2.0)
        rtt.append((time.perf_counter() - t0) * 1000)
        time.sleep(0.013)
    rtt.sort()
    res["DSR rtt ms"] = {"min": round(rtt[0], 2), "p50": round(rtt[20], 2),
                         "p90": round(rtt[36], 2), "max": round(rtt[-1], 2)}
    t0 = time.perf_counter()
    for q in BATCH:
        t.ask(q)
    res["20 queries one by one ms"] = round((time.perf_counter() - t0) * 1000, 1)
    t.read_until(lambda b: False, 0.3)
    t0 = time.perf_counter()
    t.ask("".join(BATCH), timeout=3.0)
    res["20 queries in one write ms"] = round((time.perf_counter() - t0) * 1000, 1)
    return res


def show(value):
    if isinstance(value, str):
        return value.encode("unicode_escape").decode() or "(no reply)"
    return json.dumps(value, ensure_ascii=False)


def report(res, out=sys.stdout):
    for key, value in res.items():
        if isinstance(value, dict) and key.startswith("width"):
            continue
        out.write("%-28s %s\n" % (key, show(value)))
    if "width" in res:
        out.write("\n%-28s %8s %8s\n" % ("glyph", "2027 off", "2027 on"))
        for label, _ in GLYPHS:
            out.write("%-28s %8s %8s\n" % (label, res["width"].get(label), res["width 2027"].get(label)))


def main(argv):
    if len(argv) == 3 and argv[1] == "--report":
        with open(argv[2]) as f:
            report(json.load(f))
        return 0
    path = argv[2] if len(argv) == 3 and argv[1] == "--json" else None
    t = Tty()
    res = {"TERM": os.environ.get("TERM"), "TERM_PROGRAM": os.environ.get("TERM_PROGRAM"),
           "SSH_CONNECTION": bool(os.environ.get("SSH_CONNECTION"))}
    try:
        t.write("\x1b[?1049h\x1b[?25l")
        res.update(measure(t))
    finally:
        # Put back only what this run changed, as it was: a blind ?2027l would switch a Ghostty
        # user's shell (2027 set by default) to narrow emoji.
        t.write(t.restore_modes(tuple(t.touched)) + "\x1b[0m\x1b[H\x1b[2J\x1b[?25h\x1b[?1049l")
        t.read_until(lambda b: False, 0.3)          # late answers must not reach the shell
        t.restore()
    if path:
        with open(path, "w") as f:
            json.dump(res, f, ensure_ascii=False, indent=1)
    report(res)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
