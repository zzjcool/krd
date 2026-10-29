#!/bin/bash
#
# Build krd from this checkout and install it to ~/bin/krd with a stable signature.
# For normal use the README one-liner (curl … | sh) downloads a release instead.
# Build, then install to a stable path and sign with a *stable* identity.
#
# macOS TCC keys Screen Recording on the code signature. Ad-hoc signing ("-") produces a
# new cdhash on every build, so the permission stops matching and SCK starts failing with
# -3801 "The user declined TCCs". A real signing identity keeps the designated requirement
# stable, so one approval survives every rebuild.
set -e
cd "$(dirname "$0")"
swift build -c release
mkdir -p "$HOME/bin"
cp .build/release/krd "$HOME/bin/krd"

identity="${KRD_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$identity" ]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$identity" ]; then
    echo "warning: no signing identity found, falling back to ad-hoc (TCC will need re-approval after each build)"
    identity="-"
fi
# Frozen on purpose: macOS TCC records the Screen Recording grant against this
# identifier, so renaming it would force a fresh approval (and look like a broken build).
codesign --force --sign "$identity" --identifier com.kkrt.macdesk "$HOME/bin/krd" >/dev/null 2>&1
echo "installed $HOME/bin/krd  (signed: $identity)"
