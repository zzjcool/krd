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

## The rung *is* reached end-to-end at 600 B/tick, and it delivers 10.1 fps

    harness.py --label knee-600 --fps 20 --quality auto --drain-bytes 600 --tick-ms 50 --seconds 90

    drain ceiling 11.7 KB/s, measured 8.5 KB/s
     6.36s  20/80 -> 20/70      16.47s  20/50 -> 15/50   <- the rung under test
    11.40s  20/70 -> 20/50      27.31s  15/50 -> 10/50   <- stepped past it in one window
    36.50s  10/50 -> 15/50      50.41s  15/50 -> 10/50
    77.51s  10/50 -> 15/50      83.70s  15/50 -> 10/50

In the window after 16.47 s the rung asked for 15 fps and the loop drew

    fps_median 10.1   fps_mean 10.45   fps_max 12.0   delivered_ratio_of_rung 0.67

i.e. exactly `50 ms x ceil(66.67 / 50)` = 100 ms. Six of the eight transitions are the
governor ping-ponging 15 <-> 10 because the 15 rung always measures short.

At 1024 B/tick (20 KB/s ceiling, 14.2 KB/s measured) the ladder never steps at all
(`changes: []`, `write_ms_p50 0.0`, fps_median 18.0) — the link is too fast to create
pressure, which is why the first attempt at this measurement looked like #93.

## The red test

    KRD_RED=1 swift test --filter FpsRungGateTests
    error: ... ("10.1") is not equal to ("15.0") +/- ("0.5")
           - the 15 fps rung delivered 10.1 fps from a 20 fps source

The gate (`Sources/krd/main.swift:2570-2573`) measures from the last frame that *drew*, so the
delivered period is `sourcePeriod * ceil(due / sourcePeriod)`: 50 ms x ceil(66.67/50) = 100 ms.
Every second frame is dropped and the q50/15 rung is indistinguishable from the q50/10 rung.
