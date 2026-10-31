# #92 step 2 — fusing quantise into `TileGrid.extract`: measured, and slower

**Verdict: do not ship the fusion.** It is byte-identical (proven, see the PR) and it removes a pass,
but the pass it removes is cheaper than the one it creates: after step 1 (#177) the quantise walk runs
on an L1-hot tile and the copy it is fused into is a vectorised `memcpy`, so replacing both with one
scalar loop over cold frame memory costs ~1.6x the two passes it replaces on the case the issue is
about.

Numbers are `krd --bench --json --rounds 12 --pane 137x44 --cell 17x33 --source 1920x1200`, p50 ms,
two interleaved runs of each binary on the same machine, minutes apart. `base` = `origin/main`
(`0241541`, i.e. **with** step 1). `fused` = the branch of this PR.

| case | base `ms.quantise` | base `ms.extract` | base sum | fused `ms.extract` (copy+map) | fused `ms.quantise` |
|---|---:|---:|---:|---:|---:|
| photo | 4.17 / 4.23 | 2.02 / 2.97 | **6.20 / 7.20** | **10.08 / 12.81** | 0.000 |
| photoReal | 4.20 / 4.18 | 2.19 / 2.03 | **6.40 / 6.21** | **9.47 / 21.81** | 0.000 |
| drag | 0.109 / 0.108 | 0.205 / 0.276 | 0.31 / 0.38 | 0.47 / 0.82 | 0.000 |
| char | 0 | 0.009 / 0.004 | 0.009 | 0.007 / 0.006 | 0.000 |
| line | 0 | 0.189 / 0.116 | 0.19 / 0.12 | 0.32 / 0.11 | 0.000 |
| full | 0 | 2.11 / 1.75 | 2.11 / 1.75 | 1.79 / 1.90 | 0.000 |
| gradient | 0 | 1.51 / 1.23 | 1.51 / 1.23 | 1.42 / 1.80 | 0.000 |
| ui | 0 | 1.91 / 1.46 | 1.91 / 1.46 | 1.78 / 1.68 | 0.000 |
| none | 0 | 0.000 | 0.000 | 0.000 | 0.000 |

Cases that never quantise are a wash (the fused copy is `memcpy` when `bits == nil`), which is what
makes the quantised column the whole story: `photo` 6.2 → 10.1 ms, `photoReal` 6.4 → 9.5 ms.

## Why, in one line each

* `memcpy` moves a tile's 199 KB at several GB/s; a scalar byte loop that also does six shifts and
  three ors per pixel does not. The fused loop replaces the fast copy as well as the slow map.
* the two-pass quantise reads and writes a 199 KB tile that `memcpy` has just put in L1/L2. The fused
  loop reads the frame, which is 10.1 MB and cold, one byte at a time.
* step 1 already took the win this fusion was aimed at. The issue's `quantise.fused-with-extract`
  2.32 ms was measured against the *pre-step-1* 15.09 ms per-pixel-array quantise; with the map
  already cheap and unrolled, there is no second pass left worth removing.

## What would change the answer

Fusing only pays if the map itself gets cheap enough to hide inside a vectorised copy (per-byte
table lookup or SIMD with per-lane shifts), i.e. it is a *quantise* optimisation that would speed up
the in-place pass too — not a reason to fuse. Until then the two-pass shape is the fast one and the
`ms.quantise` column keeps its meaning (and its `bench/budget.json` limit).

## Reproduce

```bash
git checkout origin/main   # base, includes #177
swift build -c release && .build/release/krd --bench --json --rounds 12 \
    --pane 137x44 --cell 17x33 --source 1920x1200 > /tmp/base.json
git checkout <this branch>
swift build -c release && .build/release/krd --bench --json --rounds 12 \
    --pane 137x44 --cell 17x33 --source 1920x1200 > /tmp/fused.json
# compare the two `ms.extract`/`ms.quantise` columns and `bytes.*` (which must be equal)
```
