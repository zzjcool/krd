# Round B — headless `krd ax` + CLI surface: survey notes

Session: HEAD `a438e9c`, macOS 27.0 (M4 Pro), release build. Screen was **locked** for the whole
session (frontmost app `loginwindow`, AX answered `cannotComplete` on every read), so every finding
about *success* output of `tree`/`find`/`press` is marked unproven below; findings about usage,
flags, exit codes, `doctor`, `--list` and docs are measured directly.

Artifacts: `session.txt` (verbatim transcript), `hard-timeout.sh` (the wrapper used — macOS has no
`timeout(1)`; `perl -e 'alarm N; exec @ARGV'`).

## Filed

| # | kind | title | evidence |
|---|------|-------|----------|
| #122 | bug p1 | unknown/malformed top-level flag launches the mirror instead of exit 2 | `krd --nonsense` → 4.6 KB of kitty frames on stdout, blocks; `krd --fps` same; `--fps abc` silently uses the default |
| #123 | accessibility p1 | `--json` has no error shape and flips `ax doctor`'s exit code 4 → 0 | `krd ax doctor` rc=4 vs `krd ax doctor --json` rc=0, same condition; `krd ax windows --json` → 0 B stdout, 274 B prose on stderr |
| #124 | enhancement p1 | `--list` starts with `ESC_Ga=d,d=i,i=31 ESC\` and has no `--json` | `xxd` of the first 64 bytes; `grep -c $'\x1b'` = 1 |
| #125 | documentation p2 | exit-code contract disagrees in three places (README misses 6) | README.md:112, README.zh-CN.md:92, `ax --help` tail, `AXExit` enum |

## Checked and clean (do not re-file)

- `install.sh --help` and `docs/DEPLOY.md:19` agree on `--prefix`, `--version`, `--sign`,
  `--from-source`; env vars `KRD_REPO/KRD_VERSION/KRD_PREFIX/KRD_SIGN_IDENTITY` documented in the
  script's own help.
- 10-flag README ↔ binary spot-check (`--fps`, `--display`, `--window`, `--tile`, `--format`,
  `--scale`, `--quality`, `--clipboard`, `--dry-run`, `--symbols`): spelling and default values
  agree, both languages.
- `krd ax` usage errors are good: unknown option / unknown command / missing ref / missing `--text`
  all exit 2 with a pointed sentence plus the usage block (`AXCommand.swift:152-209`).
- The `--json` success shapes that were reachable (`ax doctor --json`) are ANSI-free.
- `--dry-run` exists for both writes (`press`, `set`) and is rejected for reads with an explicit
  message (`AXCommand.swift:184`).
- `krd ax doctor`'s prose on a locked Mac is genuinely actionable and names the two causes.

## Saw but unproven

- Whether `tree --json` / `find --json` success shapes are stable across dumps (field order, refs,
  sanitisation) — the AX backend never answered.
- `press` read-back text and the `rc=6` path — needs a live app.
- SIGPIPE behaviour of `krd ax ... | head -3`: the AX failure (rc=4) fired first every time, so the
  pipe case never got a chance to short-write. Same for `--stats-json` under a closed pipe.
- `krd ax tree -d 2` with no `--app` returns rc=4 here, but `AXCommand.swift:988` says that should
  be a usage error (`rc=2`): the preflight runs before the per-verb argument guard, so on a locked
  Mac a usage mistake is masked by an environment error. Needs an unlocked screen to confirm the
  ordering is the cause rather than a missing `--app` fallback.
- `wall` symlink and the `--said`/`--wall-at` round-trip: only the help text was read.

## Independent adversarial review (scout `verify-b3`, read-only)

Every claim was re-measured by a node that did not write the issues. Result: all four substantively
confirmed, no duplicates among 35 open issues. Three citation corrections were applied to the filed
bodies (`fix122.md`…`fix125.md` are the final versions):

- #122: the unknown-flag swallow is `main.swift:505` (top-level switch), not `:394` (inner
  `--format` switch). Two extra facts it surfaced: krd **traps SIGTERM and exits 0**, so a wrapper
  that kills a mistyped mirror records *success*; and `main.swift:347-349` shows the author already
  guards this class for `--scale` ("a typo here doubles the bytes on the wire") but not for `--fps`.
- #125: the `--help` pointer is source `main.swift:244` (help line 92 is its rendered position);
  the `AXExit` enum is `AXCommand.swift:18-27`, not `18-33`.
- #124: the escape byte is confirmed byte-identical, but "24 lines / two shields" in the body was
  runtime-dependent — reworded to 38 lines / three shields with the reason.

Caveat the reviewer raised, and it is the honest one for #123: the AX backend recovered mid-session
(`cannotComplete` → answering) while the screen stayed locked, so "locked screen ⇒ cannotComplete"
is not a precondition you can rely on. The defect does not depend on it — `AXCommand.swift:411`
returns `.ok` whenever `options.json` is set, before the `answers ? ok : environment` ternary on the
next line — but the *live capture* of the 4-vs-0 pair is a single sample, not a repeatable one.
