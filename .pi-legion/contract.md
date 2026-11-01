# Round B — landing wall (ux-wall) — contract

Surface: `krd` with no args (the wall). Mission: experience the product in a real pane, find
where the interaction/UX is worse than `docs/design-overview.md` claims, file ≤4 `enhancement`
issues (+1 `bug`) grounded in a session actually run.

**No product source changes this round** (mission rule). Only new files under `bench/` and `/tmp`.

## Deliverables (frozen)

| # | kind | title (as filed) | state |
|---|---|---|---|
| #112 | enhancement p1 | `⤢ 3` in the band header is a control nobody can press — windows-per-page cannot be changed at all | filed, https://github.com/zzjcool/krd/issues/112 |
| #113 | bug p2 | a card caption is drawn under the card box, not under its picture (5–16 cells left) | filed, https://github.com/zzjcool/krd/issues/113 |
| #114 | documentation p2 | `--mock` cannot reach the wall — it silently opens the mirror; §10/§11.6 say otherwise | filed, https://github.com/zzjcool/krd/issues/114 |
| — | comment on #83 | measured stage-width evidence for the 7:3 split (`54–64 %` width at cell 8×16) | posted |
| — | artifacts | `bench/ux-wall-round-b/{README.md,pane-shot.sh}`; captures in `/tmp/krd-overnight/ux-wall/` | committed `ce31fed` |
| — | draft PR | https://github.com/zzjcool/krd/pull/119 (draft, notes only, no merge) | open |

## Evidence contract (each issue must cite all of these)

1. the exact command(s) run and the pane size;
2. a pane-text excerpt (`rex capture --trim`, placeholders as cells) or a log line;
3. `file:line` at HEAD `a438e9c` for the hook;
4. the design-document section it contradicts;
5. a proposal whose cost and risk are stated.

## File ownership

* `bench/ux-wall-round-b/**` — this node only.
* `/tmp/krd-overnight/ux-wall/**` — artifacts, not tracked.
* `Sources/**`, `Tests/**`, `docs/**` — **untouched** (verified by `git diff --stat origin/main...HEAD`).

## Verification

`legion-verify` (must exit 0):

```sh
set -e
test "$(git diff --name-only origin/main...HEAD | grep -c '^Sources/' || true)" = "0"
gh issue view 112 --repo zzjcool/krd --json state,labels -q '.state + " " + ([.labels[].name]|join(","))' | grep -q 'OPEN'
gh issue view 113 --repo zzjcool/krd --json state -q .state | grep -q 'OPEN'
gh issue view 114 --repo zzjcool/krd --json state -q .state | grep -q 'OPEN'
gh pr view 119 --repo zzjcool/krd --json isDraft -q .isDraft | grep -q true
grep -q 'ux-wall | #112 | round-B' /tmp/krd-overnight/FILED.md
```

## Out of scope / unproven (stated, not hidden)

* masks and their one-word reasons, the footer's "grant Screen Recording" notice, CJK/emoji/long
  titles, `window N` without a grant, >1 display, >4 windows: unreachable from `--demo`
  (`bench/ux-wall-round-b/README.md` §"What a `--demo` wall cannot show");
* entering a card and returning (`⬅ back`, page preserved, wall recaptured): the wall `exec`s a
  real mirror, which is forbidden on this machine (`--mock` cannot reach the wall either, #114);
  the *page-preservation* half was checked by resizing instead (page `2–4 / 4` survived).
