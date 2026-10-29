#!/usr/bin/env python3
"""Compare two `krd --bench --json` files from the same machine.

Timing is compared on p50, not p99: with 30 samples the p99 of a laptop that is also running
a browser moves by tens of percent between two runs of the same binary, and a gate built on it
would be turned off. p99 is still printed in report.md for humans.

    python3 bench/compare.py before.json after.json [--tolerance 5]

Exit code 1 when bytes or p99 move by more than the tolerance in the wrong direction.
"""
import argparse
import json
import sys


def pct(before, after):
    if not before:
        return 0.0 if not after else 100.0
    return 100.0 * (after - before) / before


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--tolerance", type=float, default=5.0)
    args = ap.parse_args()

    with open(args.before) as handle:
        before = {c["name"]: c for c in json.load(handle)["cases"]}
    with open(args.after) as handle:
        after = {c["name"]: c for c in json.load(handle)["cases"]}

    print("%-10s %12s %12s %8s   %9s %9s %8s" % ("case", "payload", "payload", "delta",
                                                 "p50", "p50", "delta"))
    failed = 0
    for name in sorted(set(before) & set(after)):
        b, a = before[name], after[name]
        db = pct(b["bytes"]["payload"], a["bytes"]["payload"])
        tb = b["ms"]["total"]["p50"]
        ta = a["ms"]["total"]["p50"]
        dt = pct(tb, ta)
        flags = []
        if db > args.tolerance:
            flags.append("bytes")
        if dt > args.tolerance:
            flags.append("p50")
        print("%-10s %12d %12d %+7.1f%%   %8.2f %8.2f %+7.1f%%  %s"
              % (name, b["bytes"]["payload"], a["bytes"]["payload"], db, tb, ta, dt,
                 "REGRESSION " + ",".join(flags) if flags else ""))
        failed += 1 if flags else 0
    if failed:
        print("\ncompare: %d case(s) regressed by more than %.1f%%" % (failed, args.tolerance))
        return 1
    print("\ncompare: no regression above %.1f%%" % args.tolerance)
    return 0


if __name__ == "__main__":
    sys.exit(main())
