# Security

## What krd is, security-wise

krd is a **remote control**, not a remote-display service. Whoever can run it on a Mac gets:

- a live picture of that Mac's screen (ScreenCaptureKit, Screen Recording permission), and
- the ability to click and type on it anywhere (CGEvent injection, Accessibility permission).

That is the feature. Everything below follows from it.

## What it does *not* do

- **Opens no socket.** There is no listener, no port, no protocol handler, no mDNS/Bonjour
  advertisement. The only channel is stdout/stdin of the process that ran it.
- **Authenticates nobody.** There is no password, token or key of its own. All access control is
  whatever your SSH setup provides — that is deliberate: SSH already has keys, 2FA, bastion hosts,
  `ProxyJump` and audit logs.
- **Encrypts nothing of its own.** Traffic is protected by SSH, or not at all (e.g. a local pane).
- **Persists nothing.** Nothing is installed, nothing starts on its own, nothing is scheduled, and
  no screen content is cached. The process exits when you quit (Ctrl-\\) or when the session ends.
- **Stores no credentials.** It reads no file or keychain item to run.

## Threat model

| Attacker has | Can they control the desktop? |
|---|---|
| Shell access as the same user on that Mac | yes — they could run krd themselves anyway |
| Network access only | no — nothing is listening; they would have to get into SSH first |
| The ability to get you to run `krd --list` | they can inject escapes into your terminal via a window title (see below), not control the Mac |

Two things worth being explicit about:

1. **A shell as that user is already game over.** krd adds no privilege; it just makes the desktop
   reachable from that shell. Harden SSH, not krd.
2. **The grants are the real asset.** With Screen Recording + Accessibility, any process running as
   that user can already capture the screen and synthesize events. Audit which binaries hold those
   grants (System Settings → Privacy & Security) rather than assuming krd is the only one.

## Hardening a deployment

- Restrict SSH: keys only, no password auth, `AllowUsers`, and a `Match` block or firewall rule for
  where logins may come from. krd is exactly as safe as the shell that starts it.
- Prefer `--no-input` for watch-only sessions; it never opens stdin and never injects events.
- Use `KRD_Q` only when debugging: `KRD_Q=0` makes the terminal's replies arrive on stdin, where
  they are parsed as keystrokes.
- Revoke access instantly by removing the two entries in Privacy & Security; krd then captures
  nothing and injects nothing. Add `--no-input` if you want the picture but no control.
- Do not deploy krd on a shared or kiosk machine where other people can run arbitrary binaries as
  the same user.

## Known issue: escape injection via window titles (`--list`)

`--list` prints window titles verbatim to stdout. Any application can set its own window title, and a
title containing control characters would be interpreted by the terminal that printed it (title
changes, OSC 52 clipboard writes, cursor manipulation, …). Mitigations: run `--list` in a terminal
you do not mind being poked at, or pipe it through a filter (`krd --list | cat -v`). A future
version should sanitize the titles before printing; treat this as a known limitation rather than a
deployment blocker.

## Supported versions

Only the latest release / `main` is supported. Fixes are not backported.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Use GitHub's private vulnerability
reporting ("Security" tab → "Report a vulnerability") on this repository, and include:

- macOS version, terminal (name + version), local or `ssh -t`;
- the exact command line and any environment variables;
- a reproduction, and what an attacker gains beyond "what the SSH account could already do".

You will get an acknowledgement as soon as the maintainers see it; please allow time for a fix
before publishing. Reports about the *terminal* (e.g. a terminal mishandling an escape sequence krd
sends only in a documented, deliberate way) are worth sending to that terminal's maintainers, but
tell us too — we want the compatibility note.
