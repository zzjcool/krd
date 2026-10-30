"""The hands. Every verb here changes the target, so every one of them is explicit.

Two ways to hit something, and the difference is not cosmetic:

  by ref / mark  Accessibility — `AXPress` on the node itself. Survives a window move, works on an
                 occluded window, and cannot land on whatever happened to be on top.
  by point       CGEvent — a real click. The only way to test what a *person* would hit, which is
                 what this project is: some bugs only exist in the mouse path (a drag that never
                 starts, a hit-test that is off by a cell).

`click --mark` accepts both: it presses through Accessibility by default and falls back to the
centre point with `--point`.
"""

import json
import shlex
import time

from .core import EXIT_UNKNOWN, KagentError
from . import perceive


def driver(target, *argv, timeout=60):
    return target.run([target.driver, "input"] + [str(a) for a in argv], timeout=timeout)


def click(target, x, y, button="left", count=1):
    return driver(target, "click", x, y, "--button", button, "--count", count) \
        .raise_on_error("click")


def move(target, x, y):
    return driver(target, "move", x, y).raise_on_error("move")


def drag(target, x1, y1, x2, y2, steps=24, button="left"):
    return driver(target, "drag", x1, y1, x2, y2, "--steps", steps, "--button", button) \
        .raise_on_error("drag")


def scroll(target, dy=0, dx=0, x=None, y=None):
    argv = ["scroll"]
    if x is not None and y is not None:
        argv += [x, y]
    argv += ["--dy", dy, "--dx", dx]
    return driver(target, *argv).raise_on_error("scroll")


def type_text(target, text):
    return driver(target, "type", text).raise_on_error("type")


def key(target, combo):
    return driver(target, "key", combo).raise_on_error("key")


def mark_center(artifacts, n):
    marks = artifacts.dir / "marks.json"
    if not marks.exists():
        raise KagentError("no marks: run `kagent see --marks` first", EXIT_UNKNOWN)
    for mark in json.loads(marks.read_text()):
        if mark["n"] == int(n):
            x, y, w, h = mark["rect"]
            return mark, (x + w // 2, y + h // 2)
    raise KagentError("mark %s is not in the last capture (1..%d)"
                      % (n, len(json.loads(marks.read_text()))), EXIT_UNKNOWN)


def click_mark(target, artifacts, n, point=False, button="left"):
    """Click an element by the number drawn on the last marked capture."""
    mark, (x, y) = mark_center(artifacts, n)
    if point or not mark.get("ref"):
        click(target, x, y, button=button)
        return {"via": "point", "at": [x, y], "mark": mark}
    result = perceive.press(target, mark["ref"])
    if result.rc == 0:
        return {"via": "ax", "ref": mark["ref"], "mark": mark, "out": result.text.strip()}
    # A refused AXPress is a real answer ("this node does not implement it"), not a dead end: the
    # point path is what a person would have done anyway.
    click(target, x, y, button=button)
    return {"via": "point-fallback", "at": [x, y], "mark": mark,
            "ax_said": result.error_text.strip() or result.text.strip()}


def image_to_point(artifacts, x, y):
    """A coordinate read off a `see` frame, converted to the point `click` takes."""
    last = artifacts.dir / "last-shot.json"
    if not last.exists():
        raise KagentError("no frame yet: run `kagent see` before clicking image coordinates",
                          EXIT_UNKNOWN)
    meta = json.loads(last.read_text())
    scale = meta["scale"]
    bounds = meta["bounds"]
    return (round(float(x) * scale + bounds["x"]), round(float(y) * scale + bounds["y"]))


def launch(target, name):
    return target.run(["open", "-a", name]).raise_on_error("open -a %s" % name)


def quit_app(target, name):
    script = 'osascript -e %s' % shlex.quote('tell application "%s" to quit' % name)
    return target.run_sh(script).raise_on_error("quit %s" % name)


def focus(target, spec, attempts=3):
    """Bring an app forward and *check* that it arrived.

    `open -a` returns as soon as launch services accepts the request, which is not the same as the
    app being frontmost: it can be starting, or it can refuse because it is mid-sheet. A scenario
    that types right after this call then types into whatever else was in front, and the check that
    fails is about the wrong thing.
    """
    before = perceive.frontmost(target)
    if before.get("app", "").lower() == str(spec).lower():
        return {"app": before["app"], "already": True, "frontmost": before}
    launch(target, spec)
    for _ in range(attempts):
        time.sleep(0.25)
        now = perceive.frontmost(target)
        if now.get("app", "").lower() == str(spec).lower():
            return {"app": now["app"], "already": False, "frontmost": now}
    return {"app": spec, "already": False, "frontmost": perceive.frontmost(target),
            "arrived": False}
