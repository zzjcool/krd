"""Scenarios: a test a person can read, an agent can run, and a bug report can carry.

A scenario is JSON, not a new DSL, because the two writers are a model emitting a fix and a human
reviewing it — and both of them already speak JSON. Each step is either a command (the same strings
`kagent` takes on the command line, so nothing here can drift from the CLI) or an expectation.

    {
      "name": "settings search finds the pane",
      "steps": [
        {"do": "app focus System Settings"},
        {"do": "see --marks"},
        {"expect": "element:field:Search"},
        {"do": "click --mark 1"},
        {"do": "type Wi-Fi"},
        {"expect": ["noelement:text:No Results"], "timeout": 5},
        {"do": "see"}
      ]
    }

Why the command strings: a scenario that restates the CLI in a second vocabulary is a scenario that
is wrong in a way nobody notices. Why fail-fast by default: a run that continues past a failed step
reports a pile of secondary failures and hides the first one.
"""

import json
import shlex
import time
from pathlib import Path

from . import predicates
from .core import EXIT_FAIL, EXIT_OK, EXIT_UNKNOWN, KagentError


class StepResult:
    def __init__(self, index, kind, text):
        self.index = index
        self.kind = kind
        self.text = text
        self.state = predicates.PASS
        self.detail = ""
        self.ms = 0
        self.output = None


def load(path):
    spec = json.loads(Path(path).read_text())
    if "steps" not in spec:
        raise KagentError("%s has no \"steps\"" % path)
    return spec


def run(spec, dispatch, artifacts, keep_going=False, scale_timeout=1.0, source=None):
    """Execute a scenario through `dispatch(argv) -> (exit_code, payload)`.

    Returns (state, report). The report is the artifact: every step's command, outcome, detail and
    duration, plus the path of every frame the run produced.
    """
    started = time.time()
    results = []
    state = EXIT_OK
    steps = list(spec.get("steps") or [])
    if spec.get("setup"):
        steps = list(spec["setup"]) + steps
    for index, step in enumerate(steps, start=1):
        if isinstance(step, str):
            step = {"do": step}
        kind = "do" if "do" in step else "expect" if "expect" in step else \
            "sleep" if "sleep" in step else "note"
        label = step.get("note") or step.get("do") or step.get("expect") or str(step)
        result = StepResult(index, kind, label)
        mark = time.time()
        try:
            if kind == "do":
                argv = shlex.split(step["do"]) if isinstance(step["do"], str) else list(step["do"])
                code, payload = dispatch(argv)
                result.state = predicates.PASS if code == EXIT_OK else \
                    predicates.UNKNOWN if code == EXIT_UNKNOWN else predicates.FAIL
                result.detail = "exit %d" % code
                result.output = payload
                if code != EXIT_OK:
                    result.state = predicates.FAIL
            elif kind == "expect":
                wanted = step["expect"]
                specs = wanted if isinstance(wanted, list) else [wanted]
                timeout = float(step.get("timeout", 10)) * scale_timeout
                stable = int(step.get("stable", 1))
                state_name, rows = predicates.wait(
                    _target_of(dispatch), specs,
                    app=step.get("app"), artifacts=artifacts,
                    timeout=timeout, interval=float(step.get("interval", 0.4)),
                    stable=stable, invert=bool(step.get("gone")))
                result.state = state_name
                result.detail = predicates.describe(specs, rows)
            elif kind == "sleep":
                time.sleep(float(step["sleep"]))
                result.detail = "slept %.2fs" % float(step["sleep"])
            else:
                result.detail = step.get("note", "")
        except KagentError as error:
            result.state = predicates.UNKNOWN if error.code == EXIT_UNKNOWN else predicates.FAIL
            result.detail = str(error)
        except Exception as error:  # a scenario is a script: one bad step must not lose the report
            result.state = predicates.FAIL
            result.detail = "%s: %s" % (type(error).__name__, error)
        result.ms = int((time.time() - mark) * 1000)
        results.append(result)
        artifacts.record({"kind": "step", "n": index, "cmd": label, "state": result.state,
                          "detail": result.detail[:2000], "ms": result.ms})
        if result.state != predicates.PASS:
            if step.get("optional"):
                result.detail += " (optional, ignored)"
                result.state = predicates.PASS
                continue
            state = EXIT_FAIL if result.state == predicates.FAIL else EXIT_UNKNOWN
            if not keep_going:
                break
        if step.get("note"):
            continue

    report = {
        "name": spec.get("name") or source or "scenario",
        "source": source,
        "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "seconds": round(time.time() - started, 2),
        "state": {EXIT_OK: "pass", EXIT_FAIL: "fail", EXIT_UNKNOWN: "unknown"}[state],
        "steps": [{"n": r.index, "kind": r.kind, "cmd": r.text, "state": r.state,
                   "detail": r.detail, "ms": r.ms} for r in results],
        "artifacts": sorted(p.name for p in artifacts.dir.glob("*")
                            if p.suffix in (".jpg", ".png", ".jsonl")),
    }
    return state, report


def _target_of(dispatch):
    return dispatch.__self__ if hasattr(dispatch, "__self__") else dispatch.target


def write_report(report, artifacts):
    (artifacts.dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# %s — %s" % (report["name"], report["state"]), "",
             "%s · %ss" % (report["started"], report["seconds"]), "",
             "| # | step | state | ms | detail |", "|---|---|---|---|---|"]
    for step in report["steps"]:
        detail = (step["detail"] or "").replace("|", "\\|").replace("\n", " ")
        lines.append("| %d | `%s` | %s | %d | %s |"
                     % (step["n"], step["cmd"], step["state"], step["ms"], detail[:200]))
    if report["artifacts"]:
        lines += ["", "artifacts:", ""] + ["- `%s`" % a for a in report["artifacts"]]
    (artifacts.dir / "report.md").write_text("\n".join(lines) + "\n")
    return artifacts.dir / "report.md"
