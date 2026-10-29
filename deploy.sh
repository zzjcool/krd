#!/bin/bash
# Install krd on another Mac over SSH.
#
#   ./deploy.sh admin@192.168.1.20            # put it in ~/bin/krd there
#   ./deploy.sh admin@host /usr/local/bin/krd
#
# Builds a universal binary (Apple Silicon + Intel), signs it here with the same
# identity `install.sh` uses, and copies the *signed* file over. Signing matters:
# macOS records the Screen Recording / Accessibility grants against the code
# signature, so an unsigned or freshly-built binary looks like a new app and the
# one-time approval has to be repeated.
set -euo pipefail
cd "$(dirname "$0")"

target="${1:?usage: ./deploy.sh user@host [remote-path]}"
remote="${2:-\$HOME/bin/krd}"

swift build -c release --arch arm64 --arch x86_64 >/dev/null
bin=".build/out/Products/Release/krd"

identity="${KRD_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$identity" ] || identity="-"
codesign --force --sign "$identity" --identifier com.kkrt.macdesk "$bin" >/dev/null 2>&1

echo "built: $(file -b "$bin" | cut -d, -f1-2)  ($(du -h "$bin" | cut -f1))"
# `cat | ssh` instead of scp: scp/sftp is disabled on some servers, and this keeps the
# signature intact (the file is copied byte for byte).
cat "$bin" | ssh "$target" "cat > $remote && chmod +x $remote" 
ssh "$target" "echo installed $remote \$(ls -l $remote | awk '{print \$5}') bytes; codesign -dv $remote 2>&1 | sed -n 's/^Identifier=/  identifier: /p'"
cat <<EOF

Next, on $target:
  1. enable Remote Login (System Settings > General > Sharing)
  2. run it once from that machine's own Terminal so macOS can ask for
     Screen Recording + Accessibility, and approve both:
         $remote --list
  3. then from here:  ssh -t $target $remote --fps 20
EOF
