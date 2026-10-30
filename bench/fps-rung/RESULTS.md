# fps-rung — what the frame-rate gate actually delivers

`harness.py` runs a real `krd --mock --dev` under a pty and drains the master at a ceiling
(what a slow link looks like from inside krd: `write(2)` blocks, `write_ms` grows, the
`QualityGovernor` calls frames late and walks its ladder). Frame counts come from krd's own
`--stats-json` (`tiles_total`, i.e. *after* the gate), the rung changes from its own `--log`.

HEAD a438e9c, macOS 27.0. `--pane 120x40`, drain ceiling 20 KB/s (1024 B per 50 ms tick,
measured 14.2 KB/s), `--dev`.

## 15 fps *is* deliverable on this link (control, `--quality 80` pinned, gate off)

    harness.py --label pinned15 --fps 15 --quality 80 --drain-bytes 1024 --tick-ms 50 --seconds 30

    fps_median 15.0   fps_mean 14.82   fps_min 13  fps_max 16   (fps_json_median 15.06)

## The 15 fps rung is never entered end-to-end — blocked by #93, not by this bug

    harness.py --label slow15 --fps 20 --quality auto --drain-bytes 1024 --tick-ms 50 --seconds 45

    changes: []      write_ms_p50: 0.0      final fps_median 18.0

The ladder never steps: at `--fps 20` a 14 KB/s drain does not produce a blocking write
(frames compress to ~10 KB/s, under the ceiling), and even under a true stall the governor
counts a hang as one late frame (#93). So the rung cannot be reached from the outside to be
measured from the outside — which is why the red test is over the gate's arithmetic:

    KRD_RED=1 swift test --filter FpsRungGateTests
    error: ... ("10.1") is not equal to ("15.0") +/- ("0.5")
           - the 15 fps rung delivered 10.1 fps from a 20 fps source

The gate (`Sources/krd/main.swift:2570-2573`) measures from the last frame that *drew*, so the
delivered period is `sourcePeriod * ceil(due / sourcePeriod)`: 50 ms x ceil(66.67/50) = 100 ms.
Every second frame is dropped and the q50/15 rung is indistinguishable from the q50/10 rung.
