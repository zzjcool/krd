# Notes for an agent working in this repository

Read [`docs/AGENT.md`](docs/AGENT.md) before a run that is supposed to end in a claim. It is the
playbook: what the machines are for, what a claim has to look like, and the traps that have already
cost time.

## Short version

- This project's bugs are in what a *terminal* does with a picture. Unit tests pin bytes; they cannot
  answer "does the picture fill its box". Measure, never guess.
- `agent/bin/kagent doctor` first. Red means stop — a missing Accessibility grant makes every click a
  no-op and every test a lie.
- The VM (`ssh krd-vm`, the default `--target`) is where eyes and hands live. The host's screen is
  locked and its pointer belongs to the user: reads and builds only.
- Rendering claims come from `kagent render` (the escape stream decoded back into pixels), not from
  a screenshot.
- A fix is proven by `kagent prove`, not by a green check: the baseline arm has to fail.
- Numbers, not adjectives. `frames=23 pictures=168 misfits=0` is a report; "looks right" is not.

```bash
agent/bin/kagent doctor
agent/bin/kagent see --marks          # or: kagent text -i
agent/bin/kagent --target host render --pane 80x24 --cell 17x33 --strict-fit -- .build/release/krd --selftest
swift build -c release && swift test
```
