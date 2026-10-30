"""The two ways an agent can look at a Mac, and when each one is right.

  pixels  (`see`)  what the screen looks like — one JPEG plus the numbers to turn a point in it
                   back into a point on the screen. Costs ~100 KB and one vision read.
  text    (`text`) what the screen *is*: roles, names, values and frames, as lines. Costs a few
                   hundred tokens for the same window and, unlike pixels, can be asserted on.

Both are needed. Pixels answer "is the picture right" (a rendered frame, a chart, a font bug);
text answers "is it there and can I press it" — and only text can be re-read a hundred times in a
loop without burning a context window. `see --marks` is the bridge: the numbered boxes come from
the same tree `text` prints, so a click by mark number and a click by ref address the same element.
"""

import json
import os
import re

from .core import EXIT_ENVIRONMENT, EXIT_REFUSED, EXIT_UNKNOWN, KagentError, Target

# Roles a person can act on. Everything else (AXGroup, AXScrollArea, AXWindow) is structure: it has
# a frame and no affordance, and drawing it would bury the four real controls under twenty boxes.
ACTION_ROLES = {
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
    "AXTextField", "AXSearchField", "AXTextArea", "AXLink", "AXTab", "AXRow", "AXCell",
    "AXSlider", "AXComboBox", "AXDisclosureTriangle", "AXIncrementor", "AXSegmentedControl",
    "AXToolbar", "AXMenuBarItem", "AXSwitch",
}
FIELD_ROLES = {"AXTextField", "AXSearchField", "AXTextArea", "AXComboBox", "AXSlider",
               "AXIncrementor", "AXCheckBox", "AXRadioButton", "AXSwitch"}

ROLE_SHORT = {
    "AXButton": "button", "AXCheckBox": "check", "AXRadioButton": "radio",
    "AXPopUpButton": "popup", "AXMenuButton": "menu", "AXMenuItem": "item",
    "AXTextField": "field", "AXSearchField": "search", "AXTextArea": "textarea",
    "AXLink": "link", "AXTab": "tab", "AXRow": "row", "AXCell": "cell", "AXSlider": "slider",
    "AXComboBox": "combo", "AXDisclosureTriangle": "disclosure", "AXIncrementor": "stepper",
    "AXSegmentedControl": "segments", "AXToolbar": "toolbar", "AXMenuBarItem": "menubar",
    "AXSwitch": "switch", "AXWindow": "window", "AXStaticText": "text", "AXGroup": "group",
    "AXScrollArea": "scroll", "AXSplitGroup": "split", "AXOutline": "outline",
    "AXTable": "table", "AXSheet": "sheet", "AXDialog": "dialog",
}


def ax(target, argv, timeout=90):
    """Run one `krd ax` subcommand and turn its exit codes into kagent's.

    krd already separates "the app refused" (6), "nothing matched" (5), "no permission" (3) and
    "the window server is gone" (4). Folding those into a single failure is how a harness starts
    blaming the wrong thing, so they are preserved.
    """
    result = target.run([target.krd, "ax"] + argv, timeout=timeout)
    if result.rc == 3:
        raise KagentError("no Accessibility permission on %s\n%s" % (target.name, result.text),
                          EXIT_REFUSED)
    if result.rc == 4:
        raise KagentError("the window server is unreachable on %s\n%s" % (target.name, result.text),
                          EXIT_ENVIRONMENT)
    return result


def screen(target):
    """Windows on screen plus the focused element — the cheapest "what is in front" there is."""
    return ax(target, ["screen", "--json"]).raise_on_error("ax screen").json()


def windows(target):
    return target.run([target.driver, "windows"]).raise_on_error("windows").json()["windows"]


def tree(target, app=None, pid=None, window=None, depth=6, interactive=True, maximum=250,
         menubar=False):
    argv = ["tree", "--json", "-d", str(depth), "--max", str(maximum)]
    if app:
        argv += ["--app", app]
    if pid:
        argv += ["--pid", str(pid)]
    if window is not None:
        argv += ["--window", str(window)]
    if interactive:
        argv.append("-i")
    if menubar:
        argv.append("--menubar")
    return ax(target, argv).raise_on_error("ax tree").json()


def focused_app(target):
    info = screen(target)
    focus = info.get("focus") or {}
    return focus.get("app"), focus.get("pid")


def _frame(node):
    frame = node.get("frame") or {}
    if not all(key in frame for key in ("x", "y", "width", "height")):
        return None
    return [int(frame["x"]), int(frame["y"]), int(frame["width"]), int(frame["height"])]


def label_of(node):
    name = (node.get("name") or "").strip()
    if name:
        return name
    detail = (node.get("detail") or "").strip()
    for key in ("value=", "title=", "desc="):
        if key in detail:
            value = detail.split(key, 1)[1].strip().strip('"')
            if value:
                return value
    match = re.search(r"id=([^ ]+)", detail)
    if match and not match.group(1).startswith("_NS:"):
        return match.group(1)
    return ""


def build_marks(target, app=None, pid=None, limit=40, min_size=8):
    """Numbered boxes for the elements a person could click, in reading order.

    The numbering is kagent's, not krd's: refs (`@e37`) are stable handles but nobody can count to
    37 on a screenshot, and the numbers have to survive a capture being resized. Each mark carries
    the ref it stands for, so `click --mark 4` can go through Accessibility instead of the mouse.
    """
    if pid is None:
        focus_app, focus_pid = focused_app(target)
        app, pid = app or focus_app, pid or focus_pid
    if not pid and not app:
        raise KagentError("nothing is focused and no --app was given", EXIT_UNKNOWN)

    data = tree(target, app=app, pid=pid, depth=6, interactive=True, maximum=400)
    nodes = data.get("nodes", [])
    seen = set()
    candidates = []
    for node in nodes:
        role = node.get("role") or ""
        frame = _frame(node)
        if not frame:
            continue
        width, height = frame[2], frame[3]
        if width < min_size or height < min_size:
            continue
        actions = [a.lower() for a in node.get("actions") or []]
        actionable = role in ACTION_ROLES or "press" in actions or "setvalue" in actions
        if not actionable:
            continue
        key = (role, frame[0] // 4, frame[1] // 4, width // 4, height // 4, label_of(node))
        if key in seen:
            continue
        seen.add(key)
        candidates.append({
            "ref": node.get("ref"),
            "role": role,
            "kind": "field" if role in FIELD_ROLES else "control",
            "label": label_of(node),
            "rect": frame,
            "enabled": "enabled" not in (node.get("detail") or ""),
        })

    # Reading order: top to bottom, then left to right, so the numbers on the picture read like text.
    candidates.sort(key=lambda c: (c["rect"][1] // 24, c["rect"][0]))
    marks = []
    for index, candidate in enumerate(candidates[:limit], start=1):
        candidate["n"] = index
        marks.append(candidate)
    return {"app": data.get("app"), "pid": data.get("pid"), "marks": marks,
            "considered": len(candidates), "truncated": len(candidates) > limit}


def see(target, artifacts, window=None, rect=None, grid=None, marks=None, cursor=False,
        max_width=1200, quality=0.72, if_changed=False, app=None, label=None, as_name=None):
    remote_frame = "/tmp/kagent-shot-%d.jpg" % os.getpid()
    remote_marks = "/tmp/kagent-marks-%d.json" % os.getpid()
    argv = [target.driver, "shot", "--out", remote_frame, "--max-width", str(max_width),
            "--quality", str(quality)]
    if rect:
        argv += ["--rect", rect]
    if grid:
        argv += ["--grid", str(grid)]
    if cursor:
        argv.append("--cursor")
    if window:
        argv += ["--window", str(resolve_window(target, window))]

    mark_info = None
    if marks:
        mark_info = build_marks(target, app=app)
        target.put(json.dumps(mark_info["marks"]).encode(), remote_marks)
        argv += ["--marks", remote_marks]

    meta = target.run(argv, timeout=120).raise_on_error("shot").json()
    local = artifacts.path("shot", "jpg", label=label)
    local.write_bytes(target.get(remote_frame))
    meta["path"] = str(local)
    meta["target"] = target.name
    meta.pop("drawn", None)

    if mark_info is not None:
        meta["app"] = mark_info["app"]
        meta["marks"] = mark_info["marks"]
        if mark_info["truncated"]:
            meta["marks_truncated_from"] = mark_info["considered"]
        (artifacts.dir / "marks.json").write_text(json.dumps(mark_info["marks"], indent=1))

    # An unchanged frame is not worth a second look, and on a 20 fps desktop it is the difference
    # between a 40-call loop costing 4 MB and costing 60 KB.
    previous = artifacts.dir / "last-shot.json"
    if previous.exists():
        try:
            old = json.loads(previous.read_text())
        except ValueError:
            old = {}
        if _same_signature(old.get("signature"), meta.get("signature")):
            meta["unchanged"] = True
            meta["previous_path"] = old.get("path")
            meta["unchanged_against"] = old.get("hash")
            meta["path"] = old.get("path")
            local.unlink(missing_ok=True)
    previous.write_text(json.dumps({"hash": meta["hash"], "path": meta["path"],
                                    "signature": meta.get("signature"),
                                    "rect": rect, "window": str(window) if window else None,
                                    "scale": meta["scale"], "bounds": meta["bounds"]}))
    if as_name:
        snapshots = artifacts.dir / "snapshots.json"
        table = json.loads(snapshots.read_text()) if snapshots.exists() else {}
        # A named snapshot is a fixed point: "the screen looked like this", kept until overwritten,
        # so an assertion after three more frames still means what it said when it was taken.
        table[as_name] = {"hash": meta["hash"], "path": meta["path"], "rect": rect,
                          "signature": meta.get("signature")}
        snapshots.write_text(json.dumps(table, indent=1))
        meta["as"] = as_name

    # The one arithmetic an agent must get right, written where it cannot be missed.
    bounds = meta["bounds"]
    meta["image_to_point"] = (
        "point = (image_x * %.4f + %d, image_y * %.4f + %d)"
        % (meta["scale"], bounds["x"], meta["scale"], bounds["y"]))
    artifacts.record({"kind": "see", "path": meta["path"], "hash": meta["hash"],
                      "unchanged": meta.get("unchanged", False), "target": target.name})
    return meta


def signature_delta(a, b, stride=8):
    """How many of the 32x24 blocks changed by more than `stride` luma, as a fraction.

    Two frames of the same screen differ by a blinking caret (one block) and, if the clock is in
    frame, by its digit (a few blocks). A menu, a window, a wrong picture differ by tens of blocks.
    Comparing fractions instead of bytes is what lets `same:` mean "nothing happened" rather than
    "not one byte moved".
    """
    import base64
    if not a or not b:
        return 1.0
    try:
        left = base64.b64decode(a)
        right = base64.b64decode(b)
    except Exception:
        return 1.0
    if len(left) != len(right) or not left:
        return 1.0
    changed = sum(1 for x, y in zip(left, right) if abs(x - y) > stride)
    return changed / float(len(left))


def _same_signature(a, b, tolerance=0.01):
    return signature_delta(a, b) <= tolerance


def resolve_window(target, spec):
    """A CGWindowID from an id, or from `app` / `title` substrings, newest match first."""
    if str(spec).isdigit():
        return int(spec)
    needle = str(spec).lower()
    matches = [w for w in windows(target)
               if needle in w["app"].lower() or needle in w["title"].lower()]
    if not matches:
        raise KagentError("no window matches %r (try `kagent windows`)" % spec, EXIT_UNKNOWN)
    best = max(matches, key=lambda w: w["rect"][2] * w["rect"][3])
    return best["id"]


def render_text(data):
    """The text channel as lines: indent is the tree, the brackets are the frame."""
    lines = []
    title = " ".join(filter(None, [data.get("app") or "", "—", data.get("title") or ""]))
    lines.append("%s (pid %s) %s" % (data.get("app") or "?", data.get("pid") or "?",
                                     ("· " + data["title"]) if data.get("title") else ""))
    _ = title
    for node in data.get("nodes", []):
        role = ROLE_SHORT.get(node.get("role"), node.get("role") or "?")
        name = label_of(node)
        frame = _frame(node)
        place = "[%d,%d %dx%d]" % tuple(frame) if frame else "[no frame]"
        actions = ",".join(node.get("actions") or [])
        bits = ["%s%s %s" % ("  " * (node.get("depth") or 0), node.get("ref") or "", role)]
        if name:
            bits.append('"%s"' % name[:120])
        bits.append(place)
        if actions:
            bits.append("{" + actions + "}")
        detail = (node.get("detail") or "").strip()
        if detail and not name:
            bits.append(detail[:80])
        lines.append(" ".join(bits))
    if data.get("truncated"):
        lines.append("… truncated at %s nodes (raise --max)" % data.get("shown"))
    return "\n".join(lines)


def press(target, ref, dry_run=False):
    argv = ["press", ref]
    if dry_run:
        argv.append("--dry-run")
    return ax(target, argv + ["--json"])


def set_value(target, ref, text, dry_run=False):
    argv = ["set", ref, "--text", text]
    if dry_run:
        argv.append("--dry-run")
    return ax(target, argv + ["--json"])
