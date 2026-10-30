#!/bin/sh
#
# krd installer -- fetches the latest release for macOS, verifies it, signs it and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/zzjcool/krd/main/install.sh | sh
#   curl -fsSL ... | sh -s -- --prefix /usr/local/bin
#   curl -fsSL ... | sh -s -- --version v0.1.1 --sign "Apple Development: me@example.com (ABCD1234)"
#   curl -fsSL ... | sh -s -- --from-source          # build with Swift instead of downloading
#
# Why sign: macOS records the Screen Recording and Accessibility grants against the code
# signature. The release binary comes unsigned, so we sign it once here with a stable
# identifier and the grant survives later upgrades.

set -eu

REPO="${KRD_REPO:-zzjcool/krd}"
PREFIX="${KRD_PREFIX:-$HOME/bin}"
VERSION="${KRD_VERSION:-latest}"
SIGN_ID="${KRD_SIGN_IDENTITY:-}"
IDENTIFIER="com.kkrt.macdesk"
FROM_SOURCE=0

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
usage: install.sh [options]

  --version <vX.Y.Z>   release to install (default: the latest one)
  --prefix <dir>       where to put the binary (default: ~/bin)
  --sign <identity>    codesign identity (default: your "Apple Development" cert if there
                       is one, otherwise ad-hoc; pass --sign adhoc to force ad-hoc)
  --from-source        clone and build with Swift instead of downloading a release
  -h, --help           this text

environment: KRD_REPO, KRD_VERSION, KRD_PREFIX, KRD_SIGN_IDENTITY
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --prefix) PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
        --sign) SIGN_ID="${2:?--sign needs a value}"; shift 2 ;;
        --from-source) FROM_SOURCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "krd is macOS only (ScreenCaptureKit), this is $(uname -s)"

fetch() {   # fetch <url> [output]
    if have curl; then
        if [ $# -eq 2 ]; then curl -fsSL --retry 3 -o "$2" "$1"; else curl -fsSL --retry 3 "$1"; fi
    elif have wget; then
        if [ $# -eq 2 ]; then wget -q -O "$2" "$1"; else wget -q -O - "$1"; fi
    else
        die "neither curl nor wget is available"
    fi
}

latest_tag() {
    # Prefer the plain HTTP redirect of /releases/latest: no API token, no rate limit.
    # The JSON API is a fallback for the rare case where the redirect is unavailable.
    # The cache-buster matters: the /releases/latest redirect is CDN-cached, so right after a
    # release it can still point at the previous tag (or at /releases if there is none yet).
    if have curl; then
        url=$(curl -fsSI -o /dev/null -w '%{url_effective}' -L \
                  "https://github.com/$REPO/releases/latest?nocache=$(date +%s)" 2>/dev/null || true)
        tag=${url##*/tag/}
        case "$tag" in v[0-9]*) printf '%s\n' "$tag"; return 0 ;; esac
    elif have wget; then
        tag=$(wget -q --max-redirect=5 --spider -S \
                  "https://github.com/$REPO/releases/latest?nocache=$(date +%s)" 2>&1 \
                  | sed -n 's#.*releases/tag/\([^[:space:]]*\).*#\1#p' | tail -1 | tr -d '\r')
        case "$tag" in v[0-9]*) printf '%s\n' "$tag"; return 0 ;; esac
    fi
    fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

pick_signer() {
    [ -n "$SIGN_ID" ] && return 0
    if have security; then
        found=$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
        [ -n "$found" ] && SIGN_ID="$found"
    fi
    [ -n "${SIGN_ID:-}" ] || SIGN_ID="adhoc"
}

work=$(mktemp -d "${TMPDIR:-/tmp}/krd-install.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

if [ "$FROM_SOURCE" -eq 1 ]; then
    have git || die "--from-source needs git"
    have swift || die "--from-source needs a Swift toolchain (Xcode or the command line tools)"
    say "==> cloning $REPO"
    git clone --depth 1 "https://github.com/$REPO.git" "$work/src" >/dev/null 2>&1 \
        || die "git clone failed"
    say "==> building (swift build -c release)"
    ( cd "$work/src" && swift build -c release --arch arm64 --arch x86_64 >/dev/null )
    bin=$(cd "$work/src" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/krd
    [ -x "$bin" ] || die "build produced no krd binary"
    cp "$bin" "$work/krd"
    VERSION=$(sed -n 's/^let krdVersion = "\(.*\)"$/\1/p' "$work/src/Sources/krd/Version.swift")
else
    if [ "$VERSION" = "latest" ]; then
        say "==> resolving the latest release of $REPO"
        VERSION=$(latest_tag)
        [ -n "$VERSION" ] || die "could not resolve the latest release of $REPO"
        say "    latest is $VERSION"
    fi
    name="krd-${VERSION}-macos-universal"
    base="https://github.com/$REPO/releases/download/$VERSION"
    say "==> downloading $name.tar.gz"
    fetch "$base/$name.tar.gz" "$work/$name.tar.gz"
    fetch "$base/$name.tar.gz.sha256" "$work/$name.tar.gz.sha256"
    say "==> verifying checksum"
    ( cd "$work" && shasum -a 256 -c "$name.tar.gz.sha256" >/dev/null ) \
        || die "checksum mismatch for $name.tar.gz"
    tar xzf "$work/$name.tar.gz" -C "$work"
    [ -f "$work/$name/krd" ] || die "archive did not contain krd"
    cp "$work/$name/krd" "$work/krd"
fi

pick_signer
if [ "$SIGN_ID" = "adhoc" ]; then
    say "==> signing (ad-hoc, identifier $IDENTIFIER)"
    codesign --force --sign - --identifier "$IDENTIFIER" "$work/krd" >/dev/null 2>&1 \
        || die "codesign failed"
else
    say "==> signing as: $SIGN_ID"
    codesign --force --sign "$SIGN_ID" --identifier "$IDENTIFIER" "$work/krd" >/dev/null 2>&1 \
        || die "codesign failed (is the identity in your keychain?)"
fi

mkdir -p "$PREFIX"
[ -w "$PREFIX" ] || die "$PREFIX is not writable (use --prefix, or sudo)"
installed="$PREFIX/krd"
have_at=$( [ -x "$installed" ] && "$installed" --version 2>/dev/null | awk '{print $2}' || true )
if [ "$have_at" = "${VERSION#v}" ]; then
    say "==> $installed is already ${VERSION#v}"
else
    # Copy to a temp name and rename, never `cp` straight onto the existing file: an in-place
    # truncation reuses the inode, AMFI keeps the old binary's validation result cached for that
    # vnode, and the new file dies at exec with `Killed: 9` (exit 137). See
    # docs/TROUBLESHOOTING.md §26b.
    cp "$work/krd" "$installed.new"
    chmod 755 "$installed.new"
    mv -f "$installed.new" "$installed"
    say "==> installed $installed ($VERSION)"
fi

# `wall` is the landing screen under its everyday name (krd --wall). A symlink, not a wrapper
# script: the binary reads argv[0], so `wall --symbols ascii` reaches the same parser and a new
# flag can never drift out of step here.
ln -sf krd "$PREFIX/wall"
say "==> linked $PREFIX/wall -> krd"

case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *) say "note: $PREFIX is not in PATH; add it or call $installed directly" ;;
esac

cat <<EOF

Next:
  1. approve Screen Recording (and Accessibility for input) the first time it runs:
       $installed --list
  2. open the landing screen:    $installed                    (exit with Ctrl-\\)
     the same under its name:    $PREFIX/wall
     mirror the whole display:   $installed --mirror --fps 20
     ...over SSH:                ssh -t <host> krd --mirror     (exit with Ctrl-\\)
  3. the terminal must speak the kitty graphics protocol: rex, Ghostty, kitty, WezTerm
     (Terminal.app does not)

Docs: https://github.com/$REPO#readme
EOF
