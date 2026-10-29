#!/usr/bin/env python3
"""L3: turn a `--stats-json` NDJSON file into percentiles and a verdict.

    krd --fps 20 --debug --stats-json /tmp/soak.ndjson --log /tmp/krd.log
    python3 bench/soak-report.py /tmp/soak.ndjson

What to look for (docs/BENCHMARK.md, Q3/Q4/Q5):
  write_max_ms  the worst time blocked in write(2) in that second
  pipe_ms       capture callback -> last byte out
  mbps          bytes/s actually written; 0 for a whole run means nothing was drawn
"""
import json
import statistics
import sys


def percentile(values, q):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * q)))]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rows = []
    with open(sys.argv[1]) as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    if not rows:
        print("soak: no samples")
        return 1

    def column(name):
        return [row.get(name, 0) or 0 for row in rows]

    mbps = column("mbps")
    write_max = column("write_max_ms")
    pipe = column("pipe_ms")
    tiles = column("tiles")
    skipped = column("skipped")
    delivered = column("delivered")

    print("samples %d (~%d s)" % (len(rows), len(rows)))
    print("%-14s %8s %8s %8s %8s" % ("", "mean", "p50", "p99", "max"))
    for name, values in (("MB/s", mbps), ("write_max ms", write_max),
                         ("pipe ms", pipe), ("tiles/s", tiles)):
        print("%-14s %8.2f %8.2f %8.2f %8.2f"
              % (name, statistics.mean(values), statistics.median(values),
                 percentile(values, 0.99), max(values)))

    stalls = sum(1 for ms in write_max if ms > 5)
    print()
    print("seconds with write blocked > 5 ms: %d of %d" % (stalls, len(rows)))
    print("frames delivered %d, skipped as identical %d"
          % (delivered[-1] - delivered[0], skipped[-1] - skipped[0]))
    if sum(mbps) == 0:
        print("VERDICT: nothing was written — static screen (correct) or nothing captured (bug)")
    elif stalls > len(rows) * 0.2:
        print("VERDICT: the terminal is behind; lower --fps or use --tile 16x8")
    else:
        print("VERDICT: within budget")
    return 0


if __name__ == "__main__":
    sys.exit(main())
