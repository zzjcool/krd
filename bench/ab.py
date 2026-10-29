#!/usr/bin/env python3
"""A/B two revisions on the same machine, and print a block you can paste into a PR.

    make bench-ab                     # working tree vs origin/main (or main)
    make bench-ab REF=v0.1.1          # working tree vs a tag
    make bench-ab REF=HEAD            # noise floor: same code twice, expect ~0%

What it does, in order:

1. `git worktree add --detach <tmp> <ref>` — the current checkout is never stashed, switched
   or touched. The "before" side is built inside the worktree.
2. Builds both sides with `swift build -c release` (a ref that does not build is a hard error,
   not a zero-delta table).
3. Alternates the runs (`--reps` each, before→after then after→before) so a warming laptop
   shows up as noise instead of as a regression on whichever side ran second.
4. Takes the **median across reps** per case, compares payload bytes and total p50,
   and fails the exit code on anything worse than `--tolerance`.
5. Writes `bench/ab-report.md` (markdown) and prints the same thing on stdout.

Why p50 and not p99: with 30 samples the p99 of a laptop that is also running a browser moves
by tens of percent between two runs of the *same* binary. p99 is printed for humans; the
verdict uses p50 and bytes.
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = ["--pane", "137x44", "--cell", "17x33", "--source", "1920x1200"]
LESSEE_KEYS = ["payload", "wire"]


def sh(command, cwd, capture=True):
    return subprocess.run(command, cwd=cwd, capture_output=capture, text=True)


def die(message):
    print("ab: %s" % message, file=sys.stderr)
    sys.exit(2)


def git(*args, cwd=None):
    result = sh(["git"] + list(args), cwd or ROOT)
    if result.returncode != 0:
        die("git %s failed: %s" % (" ".join(args), result.stderr.strip()))
    return result.stdout.strip()


def resolve_ref(wanted):
    if wanted:
        return wanted
    for candidate in ("origin/main", "main", "master"):
        if sh(["git", "rev-parse", "--verify", "--quiet", candidate], ROOT).returncode == 0:
            return candidate
    die("no ref given and none of origin/main, main, master exist (use REF=<ref>)")


def describe(ref, rev, dirty):
    return "`%s` (%s)%s" % (ref, rev, " +dirty" if dirty else "")


def bench(binary, rounds):
    result = sh([binary, "--bench", "--json", "--rounds", str(rounds)] + CONFIG, ROOT)
    if result.returncode != 0:
        die("%s --bench failed (%d): %s" % (binary, result.returncode, result.stderr[-800:]))
    if not result.stdout.lstrip().startswith("{"):
        # The old `--bench` printed a human table and ignored unknown flags, so a ref from
        # before this harness silently "succeeds" with the wrong output. Say so precisely:
        # a comparison against it would measure a different (portrait, 48-column) layout.
        die("%s does not support --bench --json: that ref predates the benchmark harness.\n"
            "       Compare against a ref that has it, or use REF=HEAD for the noise floor."
            % binary)
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        die("%s --bench --json produced unparseable output" % binary)
    return data


def median_case(runs):
    """Median across repetitions, case by case."""
    cases = {}
    for run in runs:
        for case in run["cases"]:
            cases.setdefault(case["name"], []).append(case)
    out = {}
    for name, samples in cases.items():
        def med(path):
            values = []
            for sample in samples:
                node = sample
                for part in path.split("."):
                    node = node[part]
                values.append(node)
            return statistics.median(values)
        out[name] = {
            "content": samples[0]["content"],
            "tiles": samples[0]["tiles"],
            "payload": med("bytes.payload"),
            "wire": med("bytes.wire"),
            "dedupe": med("ms.dedupe.p50"),
            "dirty": med("ms.dirty.p50"),
            "p50": med("ms.total.p50"),
            "p99": med("ms.total.p99"),
            "parallel": med("ms.parallel.p50"),
        }
    return out


def name(tokens):
    """326 -> '326 B', 4954.0 -> '4.8 KB', 10150107.0 -> '9.68 MB'."""
    value = float(tokens)
    if value < 1024:
        return "%.0f B" % value
    if value < 1024 * 1024:
        return "%.1f KB" % (value / 1024)
    return "%.2f MB" % (value / 1048576)


def delta(before, after):
    if not before:
        return 0.0 if not after else 100.0
    return 100.0 * (after - before) / before


# A relative delta on a 0.01 ms measurement is noise wearing a percentage sign: `none`
# flapped at "+30%" on 0.003 ms. Both flags need an absolute floor as well.
P50_FLOOR_MS = 0.2
PAYLOAD_FLOOR_BYTES = 16


def verdicts(before, after, tolerance):
    rows = []
    for case in before:
        if case not in after:
            continue
        b, a = before[case], after[case]
        d_payload = delta(b["payload"], a["payload"])
        d_p50 = delta(b["p50"], a["p50"])
        flags = []
        if d_payload > tolerance and (a["payload"] - b["payload"]) >= PAYLOAD_FLOOR_BYTES:
            flags.append("payload %+.1f%%" % d_payload)
        if d_p50 > tolerance and (a["p50"] - b["p50"]) >= P50_FLOOR_MS:
            flags.append("p50 %+.1f%%" % d_p50)
        rows.append((case, b, a, d_payload, d_p50, flags))
    return rows


def render(rows, before_label, after_label, meta, tolerance, failed):
    out = []
    add = out.append
    add("<!-- krd bench-ab: generated by `make bench-ab` -->")
    add("### Benchmarks: %s vs %s" % (after_label, before_label))
    add("")
    add("%s · %s cores · %s" % (meta["machine"], meta["cores"], meta["os"]))
    add("")
    add("`%s` px, %d tiles of %s, format `%s`, pane `%s`, cell `%s` · "
        "%d run%s per side, interleaved, median shown"
        % (meta["px"], meta["tiles"], meta["tile"], meta["format"],
           meta["pane"], meta["cell"], meta["reps"], "" if meta["reps"] == 1 else "s"))
    add("")
    add("| case | tiles | payload | Δ | total p50 | Δ | total p99 | Δ |")
    add("|---|---:|---:|---:|---:|---:|---:|---:|")
    for case, b, a, d_payload, d_p50, flags in rows:
        d_p99 = delta(b["p99"], a["p99"])
        mark = " ⚠" if flags else ""
        add("| %s%s | %d | %s → %s | %+.1f%% | %.2f → %.2f ms | %+.1f%% | %.2f → %.2f ms | %+.1f%% |"
            % (case, mark, a["tiles"], name(b["payload"]), name(a["payload"]), d_payload,
               b["p50"], a["p50"], d_p50, b["p99"], a["p99"], d_p99))
    add("")
    if failed:
        add("**Verdict: regression.** " + ", ".join(
            "%s (%s)" % (case, ", ".join(flags)) for case, _, _, _, _, flags in rows if flags))
    else:
        add("**Verdict: no regression above %.0f%%** (payload bytes and total p50)." % tolerance)
    add("")
    add("<sub>`payload` is the zlib stream, before base64. Times are the live path: dirty → parallel "
        "compress → escape assembly. A flag needs more than %.0f%% *and* %.1f ms / %d B of absolute "
        "change. Machine noise floor: `make bench-ab REF=HEAD`. Budget gate: `make bench`.</sub>"
        % (tolerance, P50_FLOOR_MS, PAYLOAD_FLOOR_BYTES))
    add("")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default=None, help="the 'before' side (default: origin/main, main)")
    ap.add_argument("--reps", type=int, default=3, help="runs per side, interleaved (default 3)")
    ap.add_argument("--rounds", type=int, default=20, help="measured frames per case (default 20)")
    ap.add_argument("--tolerance", type=float, default=5.0, help="percent that counts as a regression")
    ap.add_argument("--out", default=os.path.join(ROOT, "bench", "ab-report.md"))
    ap.add_argument("--keep", action="store_true", help="keep the temporary worktree")
    args = ap.parse_args()

    ref = resolve_ref(args.ref)
    before_rev = git("rev-parse", "--short", ref)
    after_rev = git("rev-parse", "--short", "HEAD")
    dirty = git("status", "--porcelain") != ""
    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    if branch == "HEAD":          # detached: still a valid "after" side
        branch = "working tree"
    before_label = describe(ref, before_rev, False)
    after_label = describe(branch, after_rev, dirty)

    tmp = tempfile.mkdtemp(prefix="krd-ab-")
    worktree = os.path.join(tmp, "before")
    before_bin = os.path.join(worktree, ".build", "release", "krd")
    after_bin = os.path.join(ROOT, ".build", "release", "krd")
    try:
        print("ab: worktree %s at %s" % (worktree, before_rev), file=sys.stderr)
        git("worktree", "add", "--detach", worktree, ref)

        for label, cwd in (("before (%s)" % before_rev, worktree), ("working tree", ROOT)):
            print("ab: building %s" % label, file=sys.stderr)
            result = sh(["swift", "build", "-c", "release"], cwd)
            if result.returncode != 0:
                print(result.stdout[-1500:], result.stderr[-1500:], file=sys.stderr)
                die("%s does not build at %s" % (label, before_rev if cwd == worktree else "HEAD"))

        before_runs, after_runs = [], []
        for rep in range(args.reps):
            order = [(before_bin, before_runs), (after_bin, after_runs)]
            if rep % 2 == 1:
                order.reverse()          # cancel out a warming machine
            for binary, sink in order:
                which = "before" if binary == before_bin else "after"
                print("ab: run %d/%d %s" % (rep + 1, args.reps, which), file=sys.stderr)
                sink.append(bench(binary, args.rounds))
    finally:
        if not args.keep:
            sh(["git", "worktree", "remove", "--force", worktree], ROOT)
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print("ab: worktree kept at %s" % worktree, file=sys.stderr)

    # A layout change is not a regression, it is a different picture: comparing a "one
    # character" tile at 8x4 against one at 16x8 would produce a spectacular number that
    # means nothing. This is the same trap the docs' old 2329-vs-816 claim fell into.
    keys = ("px", "tiles", "tile", "format", "pane", "cell")
    before_cfg = before_runs[0]["config"]
    after_cfg = after_runs[0]["config"]
    mismatched = [k for k in keys if before_cfg[k] != after_cfg[k]]
    if mismatched:
        detail = ", ".join("%s %s -> %s" % (k, before_cfg[k], after_cfg[k]) for k in mismatched)
        die("the two sides render different layouts (%s).\n"
            "       Their byte counts are not comparable -- pin the layout for the A/B\n"
            "       (--pane/--cell/--source/--tile/--format) or compare manually." % detail)

    before = median_case(before_runs)
    after = median_case(after_runs)
    config = before_cfg
    meta = {
        "machine": "%s (%s)" % (before_runs[0]["machine"]["model"], before_runs[0]["machine"]["arch"]),
        "cores": before_runs[0]["machine"]["cores"],
        "os": before_runs[0]["machine"]["os"],
        "px": config["px"], "tiles": config["tiles"], "tile": config["tile"],
        "format": config["format"], "pane": config["pane"], "cell": config["cell"],
        "reps": args.reps,
    }
    rows = verdicts(before, after, args.tolerance)
    failed = [row for row in rows if row[5]]
    report = render(rows, before_label, after_label, meta, args.tolerance, failed)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as handle:
        handle.write(report)
    sys.stdout.write(report)
    print("ab: written to %s" % os.path.relpath(args.out, ROOT), file=sys.stderr)

    if args.rounds < 10:
        print("ab: note: --rounds %d is too few for a stable p50" % args.rounds, file=sys.stderr)
    if failed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
