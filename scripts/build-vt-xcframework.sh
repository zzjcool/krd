#!/bin/sh
# Build `ghostty-vt.xcframework` — libghostty-vt as a universal (arm64 + x86_64) Apple static library —
# from the pinned Ghostty tag, and print the sha256 the pinned `binaryTarget` needs (issue #218).
#
#   scripts/build-vt-xcframework.sh [out dir]      # default: ./.artifacts (gitignored)
#
# Why this exists: `Package.swift` pins the VT with `.binaryTarget(url:checksum:)`, and there is
# nothing on the internet to point that at. `ghostty-org/ghostty` has exactly one release, the rolling
# pre-release `tip`, whose assets are re-uploaded nightly under the same name (so a checksum against it
# goes stale within a day); `v1.4.0` has a tag and no release at all. So the artifact is built once
# here, published as an asset on *this* repository, and pinned. This script is that "once".
#
# Two tools, both pinned:
#
#   Zig    0.17.0  (`build.zig.zon`'s `.minimum_zig_version`), from ziglang.org, checked against the
#                   published shasum *and* the published `.minisig`.
#   Xcode  `xcodebuild`, for `-create-xcframework`. `build.zig` gates the xcframework step on
#                   `emit_lib_vt and emit_xcframework and Darwin` + `xcodebuild` on PATH
#                   (`src/build/Config.zig` defaults `emit-xcframework` to "is xcodebuild available"
#                   in lib-vt mode).
#
# What it produces, and why it is not just `zig build`'s output: the build makes an xcframework with
# the macOS slice **and two iOS slices** (each gated on SDK detection), 51 MB in total. krd is a macOS
# program; the extra platforms are 43 MB of asset nobody downloads. The script re-creates the
# xcframework from the macOS slice alone, with the headers and module map Ghostty generates for Swift
# Package Manager (`GhosttyVt`, an umbrella over `ghostty/vt.h`) — 26 MB on disk, 8 MB zipped.
#
# Publishing is a maintainer step, deliberately not this script's: it writes the artifact and prints
# the checksum, and `docs/TESTING.md` §13 has the two-line edit that pins it.
set -eu

ZIG_VERSION="0.17.0"
GHOSTTY_TAG="v1.4.0"
GHOSTTY_COMMIT="83fb956"
# The shasums are ziglang.org/download/index.json's, for 0.17.0 (published 2026-10-01). The `.minisig`
# is the same directory's signature, over BLAKE2b-512 of the tarball, by the key ziglang.org/download
# prints: RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U.
ZIG_MINISIG_KEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"
case "$(uname -m)" in
    arm64)  ZIG_ARCH="aarch64-macos"; ZIG_SHA256="b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a" ;;
    x86_64) ZIG_ARCH="x86_64-macos";  ZIG_SHA256="4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6" ;;
    *) echo "build-vt-xcframework: uname -m says $(uname -m); this builds on Apple silicon or Intel macOS" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Default relative to *the repository*, not to the caller's cwd: the artifact has to end up where
# `KRD_VT_XCFRAMEWORK=.artifacts/ghostty-vt.xcframework` looks for it, whatever directory this was
# invoked from.
case "${1:-}" in
    "") OUT="$ROOT/.artifacts" ;;
    /*) OUT="$1" ;;
    *) OUT="$(pwd)/$1" ;;
esac
WORK="${KRD_VT_BUILD_DIR:-/tmp/krd-vt-build}"
ZIG="$WORK/zig-$ZIG_ARCH-$ZIG_VERSION/zig"

# The guards come before the first `mkdir`: a Linux box should not get half an output tree.
if [ "$(uname -s)" != "Darwin" ]; then
    echo "build-vt-xcframework: the xcframework needs Darwin + xcodebuild (this is $(uname -s))" >&2
    exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "build-vt-xcframework: no xcodebuild on PATH — that is what makes the xcframework" >&2
    exit 1
fi
mkdir -p "$OUT" "$WORK"
OUT="$(cd "$OUT" && pwd)"

# 1. Zig 0.17.0, verified twice. `brew install zig` is deliberately not an option: the formula tracks
#    stable releases, so it is not 0.17.0 on the day you need 0.17.0, and build.zig.zon refuses the
#    build with a version error that reads like a source problem.
if [ ! -x "$ZIG" ]; then
    TARBALL="zig-$ZIG_ARCH-$ZIG_VERSION.tar.xz"
    URL="https://ziglang.org/download/$ZIG_VERSION/$TARBALL"
    echo "build-vt-xcframework: fetching $URL"
    curl -fL --retry 3 -o "$WORK/$TARBALL" "$URL"
    curl -fsSL --retry 3 -o "$WORK/$TARBALL.minisig" "$URL.minisig"

    ACTUAL="$(shasum -a 256 "$WORK/$TARBALL" | cut -d' ' -f1)"
    if [ "$ACTUAL" != "$ZIG_SHA256" ]; then
        echo "build-vt-xcframework: $TARBALL is $ACTUAL, ziglang.org publishes $ZIG_SHA256" >&2
        exit 1
    fi
    echo "build-vt-xcframework: shasum ok ($ACTUAL)"

    # The signature is the second check: the shasum above is itself only as good as the index.json it
    # came from, and the signature is over the tarball. minisign's default mode is *prehashed*
    # (algorithm `ED`: Ed25519 over BLAKE2b-512 of the file), which is why this is not a plain verify.
    if command -v python3 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
        SIGDIR="$(mktemp -d)"
        trap 'rm -rf "$SIGDIR"' EXIT INT TERM HUP
        python3 - "$WORK/$TARBALL" "$WORK/$TARBALL.minisig" "$ZIG_MINISIG_KEY" "$SIGDIR" <<'PY'
import base64, hashlib, sys
tarball, sigfile, pub = sys.argv[1], sys.argv[2], sys.argv[3]
raw = base64.b64decode(pub)
assert raw[:2] == b"Ed" and len(raw) == 42, "not a minisign Ed25519 public key"
body = [l for l in open(sigfile).read().splitlines()
        if not l.startswith("untrusted") and not l.startswith("trusted")]
sig = base64.b64decode(body[0])
assert sig[:2] == b"ED", "expected a prehashed (ED) signature"
assert sig[2:10] == raw[2:10], "signature key id does not match the published key"
h = hashlib.blake2b(digest_size=64)
with open(tarball, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
open(sys.argv[4] + "/blake2b", "wb").write(h.digest())
open(sys.argv[4] + "/sig", "wb").write(sig[10:])
open(sys.argv[4] + "/pub.der", "wb").write(bytes.fromhex("302a300506032b6570032100") + raw[10:])
PY
        if openssl pkeyutl -verify -pubin -inkey "$SIGDIR/pub.der" -keyform DER -rawin \
                -in "$SIGDIR/blake2b" -sigfile "$SIGDIR/sig" >/dev/null 2>&1; then
            echo "build-vt-xcframework: minisig ok ($ZIG_MINISIG_KEY)"
        else
            echo "build-vt-xcframework: $TARBALL does not verify against $ZIG_MINISIG_KEY" >&2
            exit 1
        fi
    else
        echo "build-vt-xcframework: no python3/openssl — checked the shasum only" >&2
    fi

    tar -xf "$WORK/$TARBALL" -C "$WORK"
fi
[ -x "$ZIG" ] || { echo "build-vt-xcframework: $ZIG is not there after unpacking" >&2; exit 1; }
echo "build-vt-xcframework: zig $("$ZIG" version) at $ZIG"

# 2. Ghostty at the tag, checked out at the commit the tag pointed at when this script was written: a
#    moved tag would silently produce a different artifact, and the checksum is the only thing that
#    would notice.
SRC="$WORK/ghostty-$GHOSTTY_TAG"
if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty "$SRC"
fi
HEAD="$(git -C "$SRC" rev-parse --short HEAD)"
if [ "$HEAD" != "$GHOSTTY_COMMIT" ]; then
    echo "build-vt-xcframework: $SRC is at $HEAD, not $GHOSTTY_TAG=$GHOSTTY_COMMIT" >&2
    echo "build-vt-xcframework: rm -rf $SRC and re-run to re-clone the tag" >&2
    exit 1
fi
# A checkout at the right commit with edits in it would produce a checksum that is a fact about
# nothing. Building is not cheap enough to skip this.
if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
    echo "build-vt-xcframework: $SRC has uncommitted changes; the checksum would describe them" >&2
    git -C "$SRC" status --porcelain | head -5 >&2
    echo "build-vt-xcframework: rm -rf $SRC and re-run to re-clone the tag" >&2
    exit 1
fi

# 3. The build. `-Demit-lib-vt` is lib-vt mode (no GUI, no app bundle, no helpgen);
#    `-Demit-xcframework` is already the default when xcodebuild exists, and is passed anyway so the
#    invocation says what it needs. ReleaseFast is not decoration: it is the difference between a
#    debug-shaped 90 MB library and the one that ships, and every size number in the PR assumes it.
echo "build-vt-xcframework: building libghostty-vt $GHOSTTY_TAG (this is the slow part)"
(cd "$SRC" && PATH="$(dirname "$ZIG"):$PATH" "$ZIG" build -Demit-lib-vt -Doptimize=ReleaseFast -Demit-xcframework)
BUILT="$SRC/zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a"
HEADERS="$SRC/zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/Headers"
[ -f "$BUILT" ] && [ -d "$HEADERS" ] || {
    echo "build-vt-xcframework: zig build did not produce $BUILT" >&2
    exit 1
}
# A slice that is not universal would build here and fail on somebody else's Mac.
ARCHS="$(lipo -info "$BUILT" | sed 's/.*are: //')"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) echo "build-vt-xcframework: universal ($ARCHS)" ;;
    *) echo "build-vt-xcframework: $BUILT is not universal ($ARCHS)" >&2; exit 1 ;;
esac

# 4. macOS-only xcframework, headers and module map included. `-headers` is what puts `Headers/` and
#    the `module GhosttyVt` map next to the library, and that map is the thing a Swift target imports:
#    a static library in an xcframework without one is not importable at all.
rm -rf "$OUT/ghostty-vt.xcframework" "$OUT/ghostty-vt.xcframework.zip"
xcodebuild -create-xcframework -library "$BUILT" -headers "$HEADERS" \
    -output "$OUT/ghostty-vt.xcframework" >/dev/null

# 5. Zip it. Timestamps are normalised first so that re-running this script over the same library
#    reproduces the same bytes — the checksum is a published fact, and one that changes because a file
#    was touched is a checksum nobody can check. (A *different* library still gives a different zip:
#    the bytes are the library.)
find "$OUT/ghostty-vt.xcframework" -exec touch -t 202601020304.05 {} +
(cd "$OUT" && zip -qr -X ghostty-vt.xcframework.zip ghostty-vt.xcframework)

SIZE="$(stat -f%z "$OUT/ghostty-vt.xcframework.zip")"
SUM="$(shasum -a 256 "$OUT/ghostty-vt.xcframework.zip" | cut -d' ' -f1)"
LIB_SIZE="$(stat -f%z "$BUILT")"
echo "build-vt-xcframework: $OUT/ghostty-vt.xcframework.zip  $SIZE B  (library $LIB_SIZE B)"
echo "build-vt-xcframework: sha256 $SUM"
echo "build-vt-xcframework: publish that exact zip, then pin it in Package.swift (docs/TESTING.md §13):"
echo
echo "    .binaryTarget("
echo "        name: \"KrdVT\","
echo "        url: \"https://github.com/zzjcool/krd/releases/download/vt-$GHOSTTY_TAG/ghostty-vt.xcframework.zip\","
echo "        checksum: \"$SUM\""
echo "    ),"
echo
echo "build-vt-xcframework: and run the test against this one before publishing:"
echo "    KRD_VT_XCFRAMEWORK=$OUT/ghostty-vt.xcframework swift test --filter HeadlessRender"
