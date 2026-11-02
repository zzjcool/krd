# Deploying krd

English | [简体中文](DEPLOY.zh-CN.md)

krd is one self-contained Mach-O binary. There is nothing to install and nothing that starts
without you: you copy the file, approve two permissions once, and then run it from an SSH session
whenever you want a screen. Closing the session ends it.

## 0. The short way

On the machine that will *be viewed* (or on your laptop, if you mirror that):

```bash
curl -fsSL https://raw.githubusercontent.com/zzjcool/krd/main/install.sh | sh
```

It resolves the latest release, downloads `krd-vX.Y.Z-macos-universal.tar.gz`, checks the sha256,
signs the binary with your `Apple Development` identity (ad-hoc if there is none) and installs it to
`~/bin/krd`. Options: `--prefix DIR`, `--version vX.Y.Z`, `--sign IDENTITY`, `--from-source`.
Everything below is what that script does, plus the cases where you have to do it by hand.

## 1. What the target Mac needs

- macOS 14 (Sonoma) or newer.
- **Remote Login** enabled: System Settings → General → Sharing → Remote Login. This needs the GUI
  (or an admin `systemsetup` call); `deploy.sh` does *not* do it for you.
- Nothing else. No Swift toolchain, no Python, no Xcode — the binary is copied whole.
- ~5 MB of disk for the binary.

The machine you *view from* needs a terminal that implements the kitty graphics protocol (see the
compatibility table in the [README](../README.md#terminal-compatibility)) and an `ssh` client.

## 2. Deploy

From a checkout of this repository, on a Mac that has Xcode command line tools:

```bash
./deploy.sh user@host                    # → ~/bin/krd on the host
./deploy.sh user@host /usr/local/bin/krd # explicit destination
```

What the script does:

1. `swift build -c release --arch arm64 --arch x86_64` — one universal binary, so the target's
   architecture does not matter.
2. Signs it with the same identity `install.sh` uses (first `Apple Development: …` in
   `security find-identity -v -p codesigning`; override with `KRD_SIGN_IDENTITY=…`), and forces the
   identifier `com.kkrt.macdesk`.
3. Prints the architecture and size, then streams the signed file over `cat | ssh "cat > …"` so the
   signature is preserved byte for byte (`scp`/`sftp` are disabled on some servers).
4. Prints the installed byte count and, from `codesign -dv`, the installed identifier.

The remote directory must already exist — `cat > ~/bin/krd` does not create `~/bin`:

```bash
ssh user@host 'mkdir -p ~/bin'
./deploy.sh user@host
```

If you prefer the manual route (same architecture, no universal build):

```bash
scripts/install-from-source.sh      # builds, signs, installs to ~/bin/krd here
scp ~/bin/krd user@host:~/bin/krd   # or: cat ~/bin/krd | ssh user@host 'cat > ~/bin/krd'
ssh user@host 'codesign -dv ~/bin/krd 2>&1 | head -3'
```

Copying a *signed* file is fine; re-signing on the target is not (see §4).

### Without a local toolchain: the release tarball

Every release (`.github/workflows/release.yml`, triggered by a `v*` tag) publishes
`krd-vX.Y.Z-macos-universal.tar.gz` and a matching `.sha256` on the Releases page. That binary is
built in CI and **not** signed with any local identity, so sign it yourself before the first run —
the TCC grant is keyed to the signature, and an unsigned/ad-hoc binary will need a new approval on
every rebuild:

```bash
curl -LO https://github.com/zzjcool/krd/releases/download/vX.Y.Z/krd-vX.Y.Z-macos-universal.tar.gz
shasum -a 256 -c krd-vX.Y.Z-macos-universal.tar.gz.sha256    # or compare by eye
tar xzf krd-vX.Y.Z-macos-universal.tar.gz && cd krd-vX.Y.Z-macos-universal
codesign --force --sign "Apple Development: …" --identifier com.kkrt.macdesk krd
cat krd | ssh user@host 'cat > ~/bin/krd && chmod +x ~/bin/krd'
ssh user@host '~/bin/krd --version'      # expect X.Y.Z
```

## 3. First run: the two TCC grants

Screen Recording and Accessibility are separate grants, and both are per-machine:

| Grant | Needed for | What happens without it |
|---|---|---|
| Screen Recording | ScreenCaptureKit capture, and `--list` | capture fails (`-3801 user declined`), or the pane stays black |
| Accessibility | `CGEvent` injection (mouse, keyboard) | picture is fine, nothing responds to input |

Do this **once, on the target Mac, from its own GUI terminal** (Terminal.app or whatever is
installed there), not from an SSH session — macOS does not run a prompt for a process started by
`sshd`, and a prompt you cannot see is a prompt you cannot approve:

```bash
~/bin/krd --list        # triggers the Screen Recording prompt → approve
~/bin/krd --fps 20      # triggers the Accessibility prompt → approve (picture appears immediately)
# Ctrl-\ to quit
```

### macOS 26+: the grant goes to the *responsible process*, never to krd

TCC does not ask the process that calls ScreenCaptureKit. It asks that process's **responsible
process** — the app the user started, or the login session it runs in — and one grant covers
everything that session runs. Measured on this tree (issue #219); the evidence is in the PR.

| krd started from | the process that has to be granted | how krd behaves there |
|---|---|---|
| a GUI terminal app (Terminal, WezTerm, iTerm, Ghostty, Rex) | **that terminal app** | one prompt the first time; every krd in it, and every rebuild, captures |
| an SSH session | **`/usr/libexec/sshd-keygen-wrapper`** — the process `sshd` runs the session under | nothing prompts (no GUI session); every binary in the session captures, whatever its signature |
| a `launchd` job, a CI step with no GUI session | **the binary itself** | this is the only case where signing the binary matters |

So over SSH the grant is not krd's to get, and no amount of re-signing changes the answer. Grant the
wrapper instead — once per machine, and every later krd over SSH works:

```
System Settings → Privacy & Security → Screen Recording → +
  → Cmd-Shift-G → /usr/libexec/sshd-keygen-wrapper → Open → enable it
  → reconnect (`sshd` re-reads the grant per session) and run `ssh host ~/bin/krd --list`
```

What krd says when it is refused is now the name from that table — not "this binary", which was the
answer that could never be given:

```
krd: grant Screen Recording to rex in System Settings > Privacy & Security > Screen Recording, then re-run
krd: grant Screen Recording to /usr/libexec/sshd-keygen-wrapper (the process an SSH session runs under)
     in System Settings > Privacy & Security > Screen Recording, then reconnect and re-run
```

The wall's footer says the same thing in one row (`no picture - grant Screen Recording to …`), and a
`--mirror` that cannot start prints `Screen Recording is off for this SSH session - grant it to …`
rather than exiting silently.

**`tccutil reset ScreenCapture com.kkrt.macdesk` is not a check.** It answers `-10814 No such bundle
identifier` because it resolves *bundle* identifiers through LaunchServices, and a bare executable's
identifier is not one — while the grant (a path client such as `/usr/libexec/sshd-keygen-wrapper`) is
right there. The reporter of issue #219 read that message as "krd has no TCC entry", which is true
and irrelevant: neither machine below has a krd row, and both capture.

**`+` → `~/bin/krd` does not help in a terminal or over SSH** — macOS never asks krd there. It is only
worth doing for the third row of the table (no GUI ancestor at all).

**The tmux trick (a tmux server started from a granted GUI terminal, then `ssh -t host 'tmux attach'`)
is unverified here.** It is consistent with the rule — a child inherits the app that started the chain,
and a tmux server started from a terminal is that terminal's child — but this lane could not run it
end to end (no sshd on the host, and the test VM's SSH session is already granted at the wrapper, which
cannot be undone without writing to a TCC database). Granting the wrapper is the verified fix; treat
tmux as unmeasured.

If macOS never asks for **Accessibility**, add the binary by hand: System Settings → Privacy &
Security → **Accessibility** → `+` → select `~/bin/krd` (press `Cmd-Shift-G` to type the path) →
enable it. A stale entry can be removed with `−`.

A grant can also be reset from the command line when it gets stuck:

```bash
tccutil reset ScreenCapture com.kkrt.macdesk
tccutil reset Accessibility com.kkrt.macdesk
```

(`tccutil` needs no sudo; the identifier is the one `install.sh`/`deploy.sh` freeze. It only reaches
grants recorded against a *bundle* identifier, so on macOS 26 it usually reports that there is
nothing to reset — see above.)

`--debug` logs `krd: accessibility trusted=true|false` and, if capture fails, the exact error in
the log file — check that before guessing.

## 4. Signature stability (what it is and is not good for)

The grants above belong to the **responsible process** (§3), so on macOS 26 a stable signature is not
what decides whether a session can capture: a freshly built `Signature=adhoc` binary captures from a
granted terminal app and from a granted SSH wrapper (both measured). What signing still decides:

- **A grant recorded against the binary itself** (the `+` route, or the `launchd` row of the table)
is matched by code requirement, so ad-hoc signing breaks it: every build is a new cdhash and the
record stops matching. `install.sh`/`deploy.sh` therefore still sign with your identity when one
exists, and warn when they fall back to ad-hoc.
- **The identifier** (`com.kkrt.macdesk`) is what such a record is keyed on; changing it — even to
  "something nicer" — makes macOS treat the binary as a new app and ask again.
- **The installed path** should stay put too, for the same reason: a second copy is a second record,
  and the first one then points at nothing.
- **Never `strip`, re-sign or `xattr` the binary on the target.** Rebuild locally, re-sign locally,
  copy again.
- Updating is therefore: stop krd → `./deploy.sh user@host` → run again. Nothing to re-approve in the
  terminal or SSH cases, and nothing to re-approve in the per-binary case either, because the
  identity and the identifier did not change.
- The copy is written to `krd.new` and **renamed** into place, never `cat >` onto the existing
  file. Truncating in place keeps the inode, AMFI still has the old binary's validation result
  cached for it, and the new binary is killed at exec (`Killed: 9`, exit 137, not a word
  anywhere). If you copied by hand and the target dies instantly, see
  [TROUBLESHOOTING §26b](TROUBLESHOOTING.md#26b-after-an-update-the-remote-binary-dies-instantly-killed-9-exit-137-no-output).

Verify what is actually installed:

```bash
ssh user@host 'codesign -dv ~/bin/krd 2>&1 | head -5; file ~/bin/krd; ls -l ~/bin/krd; ~/bin/krd --version'
```

Expected: `Identifier=com.kkrt.macdesk`, a signature from your own identity (not `Signature=adhoc`),
`Mach-O universal binary with 2 architectures`, the byte count `deploy.sh` printed, and the version
that `VERSION` / `Sources/krd/Version.swift` carry.

## 5. Running it

```bash
ssh -t user@host ~/bin/krd --fps 20 --debug --log ~/krd.log
```

- **`-t` is mandatory.** Without a tty on stdin krd disables input and falls back to 80×24 cells.
- `--log ~/krd.log` keeps the log at a path you can read from another session
  (`ssh user@host tail -f ~/krd.log`). Without it, `--debug` writes to `$TMPDIR/krd-<pid>.log` on
  the target and prints that path once on stderr.
- `--fps 20` is the default; raise it on a LAN, lower it on a slow link. Tiles keep the byte rate
  proportional to what actually changes, so `--fps` mostly buys responsiveness, not bandwidth.
- A dropped network connection kills the pty and with it krd (it handles `SIGHUP`/`SIGTERM` and
  restores the terminal). For long-lived sessions over unreliable links, add
  `-o ServerAliveInterval=30 -o ServerAliveCountMax=3` so the session fails fast and cleanly
  instead of freezing.

Then use it like a local desktop: click, drag, scroll, type. Ctrl-\\ quits and leaves the terminal
in a clean state.

## 6. Operating notes

- **Nothing runs unless you start it.** krd is a foreground process in your SSH session; when you
  leave, it is gone. There is nothing else to install, enable or keep alive.
- **No port is opened** on the target. Everything rides the SSH session, so nothing needs a firewall
  rule and no service can be reached by anyone who cannot already SSH in.
- **Sleep ends the picture.** krd does not prevent the Mac from sleeping; macOS stops delivering
  screen content when the session sleeps or locks (black frames).
- **One viewer per process.** Each SSH session starts its own krd with its own capture stream —
  fine for two or three viewers, wasteful beyond that.
- **Uninstall** is `rm ~/bin/krd` plus removing the two entries from Privacy & Security. There is no
  receipt, plist or cache to clean up.

## 7. Deploying to several Macs

```bash
for host in mac-mini@10.0.0.11 macbook@10.0.0.12; do
  ssh "$host" 'mkdir -p ~/bin'
  ./deploy.sh "$host"
done
```

Each one still needs its own one-time grant (§3) — grants are per machine and are not transferable —
but note *who* is granted: the terminal app on that Mac if you ever run krd there from a window, and
`/usr/libexec/sshd-keygen-wrapper` if you only ever run it over SSH.
