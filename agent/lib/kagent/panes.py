"""Driving the real terminal: krd in a Rex pane, read back through its own text buffer.

The VM answers "what does a Mac look like"; it cannot answer "what does *this terminal* do with it",
because it has no kitty-graphics terminal. Rex does, and it renders without needing anyone to look at
a screen — `rex capture --format=vt` returns the text buffer, in which every picture leaves a grid of
`U+10EEEE` placeholder cells. So an agent can run krd, type into it, and measure the layout while the
host's display is locked.

What this path can and cannot see, said once so nobody has to rediscover it: it sees every character
krd draws and the *cells* its pictures occupy, and it cannot see the pictures themselves. For pixels
use `kagent render`, which decodes the escape stream; for the product's own view of a Mac use the VM.
"""

import json
import os
import shutil
import subprocess

from .core import EXIT_ENVIRONMENT, EXIT_UNKNOWN, KagentError, REPO


def _rex(args, timeout=60):
    if shutil.which("rex") is None:
        raise KagentError("rex is not on PATH: the terminal instrument is unavailable",
                          EXIT_ENVIRONMENT)
    session = os.environ.get("REX_SESSION")
    if not session:
        raise KagentError("no REX_SESSION: run this from inside Rex, or set it explicitly",
                          EXIT_UNKNOWN)
    argv = ["rex"] + args
    if "-s" not in args:
        argv += ["-s", session]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        raise KagentError("rex %s failed: %s" % (" ".join(args), (result.stderr or result.stdout)[:800]),
                          EXIT_ENVIRONMENT)
    return result


class Panes:
    """The block ids this run created, so a later command can address them without guessing."""

    def __init__(self, artifacts):
        self.path = artifacts.dir / "panes.json"
        self.table = json.loads(self.path.read_text()) if self.path.exists() else {}

    def save(self):
        self.path.write_text(json.dumps(self.table, indent=1))

    def block(self, name):
        entry = self.table.get(name)
        if not entry:
            raise KagentError("no pane named %r (have: %s)"
                              % (name, ", ".join(self.table) or "none"), EXIT_UNKNOWN)
        return entry["block"]

    def add(self, name, window, block):
        self.table[name] = {"window": window, "block": block}
        self.save()


def run(artifacts, name, command, cols=None, rows=None, cwd=None):
    # A pty's size is the pane's, not the caller's: ask the shell to set it before exec, otherwise
    # krd lays out for whatever the new window happened to be and every geometry claim is wrong.
    #
    # The wrapper is a script on disk rather than `sh -c "..."`, because Rex hands COMMAND to the
    # user's login shell and a nested quoted string arrives with its quoting stripped — which
    # produced `zsh: unknown exec flag --` instead of a pane.
    argv = list(command)
    if cols and rows:
        wrapper = artifacts.dir / ("pane-%s.sh" % name)
        wrapper.write_text("#!/bin/sh\nstty rows %d cols %d 2>/dev/null\nexec %s\n"
                           % (rows, cols, " ".join("'%s'" % a.replace("'", "'\\''")
                                                   for a in command)))
        wrapper.chmod(0o755)
        argv = [str(wrapper)]
    rex_args = ["window", "new", "kagent-%s" % name, "--focus=false", "--json"]
    if cwd:
        rex_args += ["-c", cwd]
    rex_args += ["--"] + argv
    window = _rex(rex_args).stdout
    data = json.loads(window)
    block = data["block_ids"][0]
    Panes(artifacts).add(name, data["window_id"], block)
    return {"name": name, "window": data["window_id"], "block": block, "command": argv}


def capture(artifacts, name, fmt="vt", trim=True):
    block = Panes(artifacts).block(name)
    argv = ["capture", "-b", block, "--format", fmt]
    if trim:
        argv.append("--trim")
    return _rex(argv).stdout


def runs(artifacts, name, cols, rows):
    from . import render
    stream = capture(artifacts, name, "vt").encode()
    return render.placeholder_runs(stream, cols, rows)


def send(artifacts, name, text, enter=False, raw=False):
    block = Panes(artifacts).block(name)
    payload = text
    if not raw:
        payload = text.replace("\\n", "\n").replace("\\t", "\t")
    if enter and not payload.endswith("\n"):
        payload += "\n"
    _rex(["send", "-b", block, payload])
    return {"sent": len(payload)}


def key(artifacts, name, combo):
    """A single key, by the name `rex keymap` uses (`ctrl-\\`, `escape`, `enter`)."""
    block = Panes(artifacts).block(name)
    try:
        _rex(["send-key", "-b", block, combo])
    except KagentError:
        # Older Rex builds only have raw bytes; map the two names this project actually uses.
        table = {"ctrl-\\": "\x1c", "ctrl-c": "\x03", "escape": "\x1b", "enter": "\r",
                 "tab": "\t"}
        if combo not in table:
            raise
        _rex(["send", "-b", block, table[combo]])
    return {"key": combo}


def close(artifacts, name):
    panes = Panes(artifacts)
    entry = panes.table.pop(name, None)
    if not entry:
        raise KagentError("no pane named %r" % name, EXIT_UNKNOWN)
    panes.save()
    _rex(["window", "close", "-s", os.environ.get("REX_SESSION", ""), "kagent-%s" % name])
    return {"closed": name}


def listing(artifacts):
    return dict(Panes(artifacts).table)
