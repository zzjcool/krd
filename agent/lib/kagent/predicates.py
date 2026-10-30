"""Assertions an unattended run can stand on, and the polling loop that makes them trustworthy.

Three outcomes, never two. A harness that answers "false" when it means "I could not look" turns a
permission problem into a product bug, and the bug report that follows costs more than the whole
scaffold — so `unknown` is a first-class answer with its own exit code (5), exactly like the
macOS-side tools this borrows from.

Predicates are strings so they can live in a scenario file and be read back verbatim:

    element:button:Save          a node with role button and "Save" in its name/value
    element:*:Untitled           any role
    noelement:sheet:Saving       inverted
    window:Safari                a window whose app or title contains this
    nowindow:Settings
    pixel:812,340=#ff8800        the colour at a screen point
    changed:<hash>               the screen no longer hashes to <hash> (from `see`)
    shell:<command>              the target runs it and exits 0
    file:/tmp/x                  the target has it
"""

import json
import re

from .core import EXIT_FAIL, EXIT_OK, EXIT_UNKNOWN, KagentError
from . import perceive

PASS, FAIL, UNKNOWN = "pass", "fail", "unknown"


def _short(role):
    for long, short in perceive.ROLE_SHORT.items():
        if long.lower() == role.lower() or short == role.lower():
            return long
    return role


def _matches(node, role, text):
    node_role = node.get("role") or ""
    if role not in ("*", "") and _short(role) != node_role.lower() and role.lower() != node_role.lower():
        if perceive.ROLE_SHORT.get(node_role, "").lower() != role.lower():
            return False
    haystack = " ".join(filter(None, [node.get("name"), node.get("detail"), node.get("role")]))
    if not text:
        return True
    return text.lower() in haystack.lower()


def evaluate(target, spec, app=None, artifacts=None, tolerance=0.01):
    """One predicate, one sample. Returns (state, detail)."""
    # A bare `changed` means "the screen moved since the last frame this run took". Aliasing it to
    # a name (`changed:before`) is the same as `diff:before`; both are tolerant, because an exact
    # hash is flipped by a blinking caret and a predicate that cannot fail is worse than none.
    if spec in ("changed", "unchanged"):
        kind, rest = spec, ""
    elif ":" not in spec:
        spec = "element:*:" + spec
    kind, _, rest = spec.partition(":")

    if kind in ("element", "noelement"):
        role, _, text = rest.partition(":")
        if not text:
            role, text = "*", role
        try:
            if not app:
                app, _ = perceive.focused_app(target)
            # The menu bar is part of the tree on purpose: half of what a scenario asserts on is
            # a menu item ("About This Mac", "Save As"), and those live under AXMenuBarItem —
            # invisible to a window-only walk.
            data = perceive.tree(target, app=app, depth=8, interactive=False, maximum=700,
                                 menubar=True)
        except KagentError as error:
            return UNKNOWN, "cannot read the accessibility tree: %s" % error
        hits = [n for n in data.get("nodes", []) if _matches(n, role, text)]
        found = bool(hits)
        wanted = kind == "element"
        state = PASS if found == wanted else FAIL
        if hits:
            node = hits[0]
            detail = "%s %s %s" % (node.get("ref"), node.get("role"), perceive.label_of(node))
            detail += " (%d match%s)" % (len(hits), "" if len(hits) == 1 else "es")
        else:
            detail = "no %s matching %r in %s" % (role, text, app or "the focused app")
        return state, detail

    if kind in ("window", "nowindow"):
        rows = perceive.windows(target)
        wanted = kind == "window"
        hits = [w for w in rows
                if rest.lower() in w["app"].lower() or rest.lower() in w["title"].lower()]
        state = PASS if bool(hits) == wanted else FAIL
        detail = ("%d window(s) match %r" % (len(hits), rest)) if hits \
            else "no window matches %r (have: %s)" % (
                rest, ", ".join(sorted({w["app"] for w in rows})))
        return state, detail

    if kind == "pixel":
        x, _, tail = rest.partition(",")
        y, _, colour = tail.partition("=")
        try:
            probe = target.run([target.driver, "probe", x, y]).raise_on_error("probe").json()
        except KagentError as error:
            return UNKNOWN, str(error)
        want = colour.lower().lstrip("#")
        got = probe["hex"].lower().lstrip("#")
        if len(want) == 3:
            want = "".join(c * 2 for c in want)
        return (PASS if got == want else FAIL), "at %s,%s: #%s (wanted #%s)" % (x, y, got, want)

    if kind in ("same", "diff"):
        snapshot = _snapshot(artifacts, rest)
        if snapshot is None:
            return UNKNOWN, "no snapshot named %r (use `see --as %s`)" % (rest, rest)
        meta = perceive.see(target, artifacts, max_width=480, rect=snapshot.get("rect"))
        delta = perceive.signature_delta(snapshot.get("signature"), meta.get("signature"))
        equal = delta <= tolerance
        wanted = kind == "same"
        state = PASS if equal == wanted else FAIL
        return state, "%s %r: %.2f%% of blocks changed (%s vs %s, tolerance %.2f%%)" % (
            "matches" if equal else "differs from", rest, delta * 100,
            meta["hash"][:12], snapshot["hash"][:12], tolerance * 100)

    if kind in ("changed", "unchanged"):
        if artifacts is None:
            return UNKNOWN, "%s needs a run directory" % kind
        last = artifacts.dir / "last-shot.json"
        if not last.exists():
            return UNKNOWN, "no previous frame: run `see` first"
        previous = json.loads(last.read_text())
        meta = perceive.see(target, artifacts, max_width=480)
        delta = perceive.signature_delta(previous.get("signature"), meta.get("signature"))
        same = delta <= tolerance
        state = (PASS if not same else FAIL) if kind == "changed" else (PASS if same else FAIL)
        return state, "%s since the last frame: %.2f%% of blocks changed (tolerance %.2f%%)" % (
            "not changed" if same else "changed", delta * 100, tolerance * 100)

    if kind == "shell":
        result = target.run_sh(rest, timeout=120)
        return (PASS if result.rc == 0 else FAIL), "exit %d: %s" % (
            result.rc, (result.text + result.error_text).strip()[-400:])

    if kind == "file":
        ok = target.exists(rest)
        return (PASS if ok else FAIL), ("%s exists" % rest) if ok else ("%s is missing" % rest)

    if kind == "app":
        rows = [w for w in perceive.windows(target) if rest.lower() in w["app"].lower()]
        return (PASS if rows else FAIL), "%d window(s) from %r" % (len(rows), rest)

    return UNKNOWN, "unknown predicate %r" % spec


def wait(target, specs, app=None, artifacts=None, timeout=10.0, interval=0.4, stable=1,
         invert=False, progress=None, tolerance=0.01):
    """Poll until every predicate holds for `stable` consecutive samples."""
    import time
    deadline = time.time() + float(timeout)
    streak = 0
    last = []
    while True:
        results = [evaluate(target, spec, app=app, artifacts=artifacts,
                            tolerance=tolerance) for spec in specs]
        if invert:
            results = [(FAIL if state == PASS else PASS if state == FAIL else UNKNOWN, detail)
                       for state, detail in results]
        last = results
        if any(state == UNKNOWN for state, _ in results):
            return UNKNOWN, last
        if all(state == PASS for state, _ in results):
            streak += 1
            if streak >= stable:
                return PASS, last
        else:
            streak = 0
        if time.time() >= deadline:
            return FAIL, last
        if progress:
            progress(results)
        time.sleep(interval)


def _snapshot(artifacts, name):
    if artifacts is None:
        return None
    path = artifacts.dir / "snapshots.json"
    if not path.exists():
        return None
    return json.loads(path.read_text()).get(name)


def exit_code(state):
    return {PASS: EXIT_OK, FAIL: EXIT_FAIL, UNKNOWN: EXIT_UNKNOWN}[state]


def describe(specs, results):
    lines = []
    for spec, (state, detail) in zip(specs, results):
        lines.append("%-5s %s — %s" % (state, spec, detail))
    return "\n".join(lines)


def hash_from_meta(meta):
    return re.sub(r"\s+", "", meta.get("hash", ""))
