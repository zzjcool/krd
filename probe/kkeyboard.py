import sys, os, select, time, tty, termios

# Kitty keyboard protocol probe. Run it in the terminal you want to know about:
#
#     python3 probe/kkeyboard.py
#
# It pushes the enhancements krd asks for (disambiguate | event types | alternate keys | all keys
# as escape codes) and then queries the effective flags. A terminal that does not implement the
# protocol stays silent, and krd keeps its legacy encoding — that is a correct answer, not an
# error. The last two lines are the ones to copy into docs/herdr-graphics-probe.log.

FLAGS = [(1, "disambiguate"), (2, "events"), (4, "alternates"), (8, "all-keys"), (16, "text")]

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
TTY = os.open("/dev/tty", os.O_WRONLY | os.O_NOCTTY)


def ask(label, seq, wait=0.7):
    os.write(TTY, seq.encode("latin1"))
    out = b""
    deadline = time.time() + wait
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            out += os.read(fd, 4096)
    text = out.decode("latin1").strip()
    print(f"{label:34s} {text if text else '(no reply)'}")
    return out


def decode(out):
    # CSI ? <flags> u
    if not out.startswith(b"\x1b[?"):
        return None
    body = out[3:]
    if not body.endswith(b"u"):
        return None
    try:
        return int(body[:-1])
    except ValueError:
        return None


try:
    # DA1 first: it proves the terminal is answering at all, so "silent" below means "no keyboard
    # protocol" and not "this script cannot read replies".
    ask("00 primary DA (control)", "\x1b[c")
    out = ask("01 keyboard flags query", "\x1b[>15u\x1b[?u")
    flags = decode(out)
    if flags is None:
        print(f"{'':34s} legacy only (push ignored, no answer)")
    else:
        names = [name for bit, name in FLAGS if flags & bit]
        print(f"{'':34s} kitty, flags={flags} ({', '.join(names) or 'none'})")
        missing = [name for bit, name in FLAGS[:4] if not flags & bit]
        if missing:
            print(f"{'':34s} WARNING: krd needs 1|2|4|8; missing: {', '.join(missing)}")
    ask("02 pop", "\x1b[<u", wait=0.3)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
