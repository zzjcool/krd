#!/usr/bin/env python3
"""Run the whole benchmark suite and write a report.

    make bench                  # encode + wire + budgets -> bench/report.md
    make bench BENCH_ARGS="--quick"
    python3 bench/bench.py --rounds 50

Three layers, one report (docs/BENCHMARK.md):

  L1  encode   krd --bench --json     the real encoder on synthetic frames
  L2  wire     bench/wire.py          krd under a pty against a rate-limited drain
  gate         bench/budget.json      absolute budgets, machine-tolerant by design

Timings are reported, not gated: a macOS runner is not the same machine class as a laptop,
and a gate that fails on runner noise gets deleted. Bytes, tile counts and the static-screen
invariant are deterministic, so those *are* gated.
"""
import argparse
import datetime
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "bench")
BINARY = os.path.join(ROOT, ".build", "release", "krd")

DEFAULT_CONFIG = ["--pane", "137x44", "--cell", "17x33", "--source", "1920x1200"]


def die(message):
    print("bench: %s" % message, file=sys.stderr)
    sys.exit(2)


def run(command, capture_stdout=True, check=True, timeout=None):
    result = subprocess.run(command, cwd=ROOT, capture_output=capture_stdout,
                            text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    if check and result.returncode != 0:
        die("command failed (%d): %s" % (result.returncode, " ".join(command)))
    return result


def git_rev():
    try:
        rev = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
                             capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT,
                               capture_output=True, text=True).stdout.strip()
        return rev + ("+dirty" if dirty else "")
    except OSError:
        return "?"


def version():
    try:
        with open(os.path.join(ROOT, "VERSION")) as handle:
            return handle.read().strip()
    except OSError:
        return "?"


def dig(object, path):
    """'ms.total.p99' -> object['ms']['total']['p99']"""
    node = object
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


# ---------------------------------------------------------------- layers

def run_encode(rounds, config):
    command = [BINARY, "--bench", "--json", "--rounds", str(rounds)] + config
    started = time.time()
    result = run(command)
    elapsed = time.time() - started
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        print(result.stdout[-2000:], file=sys.stderr)
        die("--bench --json did not produce JSON")
    data["wall_s"] = round(elapsed, 1)
    sys.stderr.write(result.stderr)
    return data


def run_wire(spec, config, quick):
    """spec: (case, drain, seconds, assert_zero)"""
    case, drain, seconds, assert_zero = spec
    if quick and drain:
        seconds = min(seconds, 0.5)
    command = [sys.executable, os.path.join(BENCH, "wire.py"),
               "--case", case, "--seconds", str(seconds), "--drain", drain]
    if assert_zero:
        command.append("--assert-zero-bytes")
    command += ["--", BINARY, "--bench-wire", case, "--fps", "20",
                "--seconds", str(seconds)] + config
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout, result.stderr, file=sys.stderr)
        die("wire harness failed for %s" % case)
    data = json.loads(result.stdout)
    data["drain"] = "unlimited" if drain in ("", "0", None) else drain
    data["label"] = case + "@" + data["drain"]
    return data


# ---------------------------------------------------------------- verdicts

def evaluate_budget(encode, wire, budget):
    checks = []
    for rule in budget.get("encode", []):
        case = next((c for c in encode["cases"] if c["name"] == rule["case"]), None)
        if case is None:
            checks.append((rule["case"], rule["field"], None, rule.get("max"), "missing case"))
            continue
        value = dig(case, rule["field"])
        ok = value is not None and value <= rule["max"]
        checks.append((rule["case"], rule["field"], value, rule["max"], "ok" if ok else "OVER"))
    for rule in budget.get("wire", []):
        run_ = next((w for w in wire if w["label"] == rule["case"]), None)
        if run_ is None:
            checks.append((rule["case"], rule["field"], None, rule.get("max"), "missing run"))
            continue
        value = dig(run_, rule["field"])
        ok = value is not None and value <= rule["max"]
        checks.append((rule["case"], rule["field"], value, rule["max"], "ok" if ok else "OVER"))
    return checks


def previous_results():
    path = os.path.join(BENCH, "results", "last-encode.json")
    if not os.path.exists(path):
        return None
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


# ---------------------------------------------------------------- report

def kb(value):
    return "%.1f KB" % (value / 1024) if value < 1024 * 1024 else "%.2f MB" % (value / 1048576)


def render(encode, wire, checks, previous, config):
    out = []
    head = encode
    tiles = head["config"]["tiles"]
    add = out.append

    add("# krd benchmark report")
    add("")
    add("Generated by `make bench` (`bench/bench.py`) on %s." % datetime.datetime.now().strftime("%Y-%m-%d %H:%M"))
    add("")
    add("| | |")
    add("|---|---|")
    add("| krd | %s (%s) |" % (head["krd"], head["build"]))
    add("| git | `%s` |" % git_rev())
    add("| machine | %s, %s, %d cores, macOS %s |"
        % (head["machine"]["model"], head["machine"]["arch"], head["machine"]["cores"], head["machine"]["os"]))
    add("| config | pane %s cells, cell %s px, tile %s, source %s pt → %s px, %d tiles |"
        % (head["config"]["pane"], head["config"]["cell"], head["config"]["tile"],
           head["config"]["source"], head["config"]["px"], tiles))
    add("| python | %s |" % platform.python_version())
    add("")

    failed = [c for c in checks if c[4] != "ok"]
    add("## Budget")
    add("")
    add("**%s** — %d checks, %d over budget." % ("FAIL" if failed else "PASS", len(checks), len(failed)))
    add("")
    add("| case | metric | measured | budget | |")
    add("|---|---|---:|---:|---|")
    for case, field, value, budget, status in checks:
        shown = "-" if value is None else ("%.0f" % value if abs(value) >= 100 else "%.2f" % value)
        add("| %s | `%s` | %s | %s | %s |" % (case, field, shown, budget, status))
    add("")

    add("## Encoder (L1)")
    add("")
    add("The real tile pipeline on synthetic frames: dedupe → dirty → extract → zlib → base64 → escapes.")
    add("Warm-up rounds discarded, p50/p99 over %d rounds. `wire` includes base64 and escapes."
        % head["config"]["rounds"])
    add("")
    add("| case | content | tiles | payload | wire | dedupe | dirty | total p50 | total p99 |")
    add("|---|---|---:|---:|---:|---:|---:|---:|---:|")
    for case in encode["cases"]:
        add("| %s | %s | %d | %s | %s | %.2f ms | %.2f ms | %.2f ms | %.2f ms |" % (
            case["name"], case["content"], case["tiles"],
            kb(case["bytes"]["payload"]), kb(case["bytes"]["wire"]),
            dig(case, "ms.dedupe.p50"), dig(case, "ms.dirty.p50"),
            dig(case, "ms.total.p50"), dig(case, "ms.total.p99")))
    add("")
    add("Per stage, single-threaded reference run (3 attempts, best) against the parallel encode:")
    add("")
    add("| case | extract | zlib | base64 | assemble | serial | parallel | speedup |")
    add("|---|---:|---:|---:|---:|---:|---:|---:|")
    for case in encode["cases"]:
        serial = dig(case, "ms.serial.p50") or 0
        parallel = dig(case, "ms.parallel.p50") or 0
        speedup = "%.1f×" % (serial / parallel) if parallel > 0 else "-"
        add("| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %s |" % (
            case["name"], dig(case, "ms.extract.p50"), dig(case, "ms.zlib.p50"),
            dig(case, "ms.base64.p50"), dig(case, "ms.assemble.p50"),
            serial, parallel, speedup))
    add("")
    add("All times in ms. `extract` and `zlib` come from the serial reference (a per-tile timer")
    add("inside `concurrentPerform` would need a lock); `total` is the live path: dirty + parallel + emit.")
    add("")

    if wire:
        add("## Wire (L2)")
        add("")
        add("krd in a pty, the other end draining at a fixed rate. `write_ms` is time blocked in")
        add("`write(2)` — the only honest backpressure signal that exists without a camera.")
        add("")
        add("| run | fps | frames | late | wire MB/s | write p50 | write p99 | pipe p50 | pipe p99 | bytes after 1st |")
        add("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for run_ in wire:
            add("| %s | %d | %d | %d | %.2f | %.2f | %.2f | %.2f | %.2f | %d |" % (
                run_["label"], (run_.get("summary") or {}).get("fps", 20), run_["frames"], run_["late"],
                run_["mbps"], dig(run_, "write_ms.p50") or 0, dig(run_, "write_ms.p99") or 0,
                dig(run_, "pipe_ms.p50") or 0, dig(run_, "pipe_ms.p99") or 0,
                run_["bytes_after_first_frame"]))
        add("")

    add("## What the numbers mean")
    add("")
    cases = {c["name"]: c for c in encode["cases"]}
    frame_budget = 50.0
    if "char" in cases:
        wire_ = cases["char"]["bytes"]["wire"]
        add("- Typing one character costs **%s on the wire** (%.1f KB/s at 20 fps)."
            % (kb(wire_), wire_ * 20 / 1024))
    if "photo" in cases:
        wire_ = cases["photo"]["bytes"]["wire"]
        add("- A full-screen photo repaint costs **%s**, i.e. %.0f MB/s at 20 fps — a link that"
            " cannot carry that blocks `write` instead of dropping frames."
            % (kb(wire_), wire_ * 20 / 1048576))
        slow = [w for w in wire if w.get("drain") not in (None, "unlimited")]
        if slow:
            add("  On a %s drain a 600×400 drag of the same content blocked `write` for **%.0f ms per frame**"
                " and every frame arrived late: krd keeps its promises, it cannot beat the link."
                % (slow[0]["drain"], dig(slow[0], "write_ms.p50")))
    if "none" in cases:
        add("- A static screen writes **%d bytes** per delivered frame — design goal #2 — but costs"
            " **%.1f ms of memcmp** to find that out, which is %.0f%% of a 50 ms frame."
            % (next((w["bytes_after_first_frame"] for w in wire if w["case"] == "none"), 0),
               dig(cases["none"], "ms.dedupe.p50"),
               100.0 * (dig(cases["none"], "ms.dedupe.p50") or 0) / frame_budget))
    if "photo" in cases and "full" in cases:
        add("- Encoder time is not the ceiling: the heaviest case uses %.0f ms of the %.0f ms frame"
            " budget at 20 fps, and `write` is where a slow link shows up."
            % (dig(cases["photo"], "ms.total.p99"), frame_budget))
    add("")

    if previous:
        add("## Change since the last run")
        add("")
        before = {c["name"]: c for c in previous.get("cases", [])}
        add("| case | payload | Δ | total p50 | Δ |")
        add("|---|---:|---:|---:|---:|")
        for case in encode["cases"]:
            old = before.get(case["name"])
            if not old:
                continue
            old_payload = old["bytes"]["payload"]
            old_total = dig(old, "ms.total.p50")
            now_payload = case["bytes"]["payload"]
            now_total = dig(case, "ms.total.p50")
            dp = 100.0 * (now_payload - old_payload) / old_payload if old_payload else 0
            dt = 100.0 * (now_total - old_total) / old_total if old_total else 0
            add("| %s | %s | %+.1f%% | %.2f ms | %+.1f%% |"
                % (case["name"], kb(now_payload), dp, now_total, dt))
        add("")
        add("Payload is content, so its delta is signal. Timing deltas on one machine minutes apart")
        add("are noise below ~5%; they are printed to be read, not to be trusted to two decimals.")
        add("")

    add("## Limits of this report")
    add("")
    add("- No terminal-side paint latency: the kitty protocol has no ack for `a=t` + `a=p`, so the")
    add("  pty can only tell us when bytes were *accepted*. Optical latency needs a camera.")
    add("- Synthetic content: `text`/`noise`/`ui`/`gradient` are generators, not a real desktop. Record")
    add("  real frames with `--record` and use `--replay` for that.")
    add("- ScreenCaptureKit is not exercised at all (no TCC, no screen); its cost is only visible in")
    add("  a live `--debug` run as `cap=` and `pipe=`.")
    add("")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=30)
    ap.add_argument("--quick", action="store_true", help="fewer rounds, shorter wire runs")
    ap.add_argument("--no-wire", action="store_true", help="encoder only")
    ap.add_argument("--no-build", action="store_true", help="use the existing binary")
    ap.add_argument("--config", default=" ".join(DEFAULT_CONFIG))
    args = ap.parse_args()

    if not args.no_build:
        print("bench: swift build -c release", file=sys.stderr)
        run(["swift", "build", "-c", "release"], capture_stdout=False)
    if not os.path.exists(BINARY):
        die("no binary at %s" % BINARY)

    with open(os.path.join(BENCH, "budget.json")) as handle:
        budget = json.load(handle)

    config = args.config.split()
    rounds = 8 if args.quick else args.rounds

    print("bench: encoder (L1), %d rounds" % rounds, file=sys.stderr)
    encode = run_encode(rounds, config)
    encode["git"] = git_rev()

    wire = []
    if not args.no_wire:
        specs = [("line", "0", 3.0, False),
                 ("none", "0", 2.0, True),
                 ("drag", "5MB", 1.0, False)]
        if args.quick:
            specs = specs[:2]
        for spec in specs:
            print("bench: wire (L2) %s drain=%s" % (spec[0], spec[1] or "unlimited"), file=sys.stderr)
            wire.append(run_wire(spec, config, args.quick))

    checks = evaluate_budget(encode, wire, budget)
    previous = previous_results()
    report = render(encode, wire, checks, previous, config)

    results = os.path.join(BENCH, "results")
    os.makedirs(results, exist_ok=True)
    with open(os.path.join(results, "last-encode.json"), "w") as handle:
        json.dump(encode, handle, indent=1)
    with open(os.path.join(results, "last-wire.json"), "w") as handle:
        json.dump(wire, handle, indent=1)
    with open(os.path.join(results, "last-checks.json"), "w") as handle:
        json.dump([{"case": c[0], "metric": c[1], "value": c[2], "budget": c[3], "status": c[4]}
                   for c in checks], handle, indent=1)
    with open(os.path.join(BENCH, "report.md"), "w") as handle:
        handle.write(report)

    # One file per version, overwritten: the git rev is recorded inside the JSON. A file per
    # commit accumulated one artifact per `make bench` run and buried the release baseline.
    history = os.path.join(BENCH, "history", "%s.json" % version())
    os.makedirs(os.path.dirname(history), exist_ok=True)
    with open(history, "w") as handle:
        json.dump({"encode": encode, "wire": wire,
                   "checks": [list(c) for c in checks]}, handle, indent=1)

    # console summary: the same tables, without the prose
    print()
    for case in encode["cases"]:
        print("  %-9s %4d tiles  %10s payload  %10s wire  %6.2f ms p50  %6.2f ms p99"
              % (case["name"], case["tiles"], kb(case["bytes"]["payload"]),
                 kb(case["bytes"]["wire"]), dig(case, "ms.total.p50"), dig(case, "ms.total.p99")))
    for run_ in wire:
        print("  wire %-12s %5d frames  %5d late  %6.2f MB/s  write p99 %6.2f ms"
              % (run_["label"], run_["frames"], run_["late"], run_["mbps"],
                 dig(run_, "write_ms.p99") or 0))
    failed = [c for c in checks if c[4] != "ok"]
    print()
    if failed:
        for case, field, value, budget_, status in failed:
            print("  BUDGET FAIL %s %s = %s (budget %s)" % (case, field, value, budget_))
        print("\nbench: %d budget check(s) failed; report: bench/report.md" % len(failed))
        return 1
    print("bench: %d budget checks passed; report: bench/report.md" % len(checks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
