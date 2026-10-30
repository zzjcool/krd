#!/usr/bin/env bash
# Build krd here, deploy it into the tart VM, keep the bundle identifier that holds its grants.
#
# Why a script: the tarball is a *snapshot*, and a stale one once deployed `placeholders = false`
# while the tree said `true` - a bug that costs an hour to find. Re-tarring is not optional, so it
# happens in the same command as the build and the copy.
#
#   .agents/skills/krd-dev/scripts/deploy-vm.sh
#   VM=other-vm PORT=8901 .agents/skills/krd-dev/scripts/deploy-vm.sh
#
# Requirements: the VM is reachable as `ssh $VM` and has Swift; the host can serve HTTP on the
# VM's gateway (192.168.64.1 is the host from inside a tart VM).
set -euo pipefail

VM="${VM:-krd-vm}"
PORT="${PORT:-8899}"
GW="${GW:-192.168.64.1}"
SRC="$(cd "$(dirname "$0")/../../../.." && pwd)"
TAR="${TMPDIR:-/tmp}/krd-src.tar"
IDENTIFIER="com.kkrt.macdesk"

cd "$SRC"

echo "==> snapshot of the tree as it is right now"
tar cf "$TAR" --exclude=.build --exclude=.git --exclude='.pi' --exclude='.pi-subagents' .
echo "    $(du -h "$TAR" | cut -f1)  $(git log --oneline -1 2>/dev/null || echo 'no git')"

echo "==> serving it on :$PORT for the guest"
python3 -m http.server "$PORT" --directory "$(dirname "$TAR")" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT

echo "==> building and installing in $VM"
ssh "$VM" bash -s <<EOF
set -euo pipefail
mkdir -p ~/krd ~/bin
curl -fsS http://$GW:$PORT/$(basename "$TAR") | tar xmf - -C ~/krd
# A snapshot keeps mtimes, and Swift skips work whose timestamps look old: touch the sources.
find ~/krd/Sources -name '*.swift' -exec touch {} +
cd ~/krd
swift build -c release
cp .build/release/krd ~/bin/krd.new
codesign --force --sign - --identifier $IDENTIFIER ~/bin/krd.new
mv ~/bin/krd.new ~/bin/krd
echo "installed: \$(ls -l ~/bin/krd | awk '{print \$5, \$6, \$7, \$8}')"
EOF

echo "==> smoke test: a sized pty, krd's own log for a few seconds"
ssh -tt "$VM" 'rm -f /tmp/krd.log; stty rows 46 cols 146; ~/bin/krd --wall --debug --log /tmp/krd.log >/dev/null 2>&1 & sleep 8; pkill -x krd; exit 0' </dev/null >/dev/null 2>&1 || true
ssh "$VM" 'grep -aE "wall cell|capture |scaled to|U=1|placeholder" /tmp/krd.log | head -6' || true

cat <<'NOTE'

Next: run it where a terminal can answer, and read the frame's numbers:
  rex send -s "$REX_SESSION" -b <block> $'ssh -t krd-vm krd --debug --log /tmp/krd.log\n'
  ssh krd-vm 'cat /tmp/krd.log'
NOTE
