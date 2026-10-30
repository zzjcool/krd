#!/usr/bin/env bash
# drive one krd --selftest run in the rex probe pane at an exact pty size, then read the text layer
# usage: run-sweep.sh <cols>x<rows> <tag> [krd flags...]
set -u
export REX_SESSION=${REX_SESSION:-session:01a18bd4-2af8-7000-8b53-b9a7d69828f2}
B=${KRD_BLOCK:-block:01a18efd-9371-7651-a85f-19d924a9b2ab}
K=${KRD_BIN:-/Users/zzj/code/kkrt/.build/release/krd}
OUT=${OUT:-/tmp/krd-overnight/bug-term}
size=$1; tag=$2; shift 2
cols=${size%x*}; rows=${size#*x}

rex send -s "$REX_SESSION" -b "$B" $'\x03' >/dev/null 2>&1; sleep 0.2
rex send -s "$REX_SESSION" -b "$B" "clear; stty rows $rows cols $cols; exec $K --selftest $* --log $OUT/$tag.log" >/dev/null 2>&1
rex send -s "$REX_SESSION" -b "$B" $'\n' >/dev/null 2>&1
sleep ${WAIT:-4}
rex capture -s "$REX_SESSION" -b "$B" --format=vt > "$OUT/$tag.vt" 2>/dev/null
rex capture -s "$REX_SESSION" -b "$B" --trim > "$OUT/$tag.txt" 2>/dev/null
echo "== $tag ($size, flags: $*)"
python3 /Users/zzj/code/kkrt/.agents/skills/krd-dev/scripts/wall-runs.py "$OUT/$tag.vt"
grep -aE "krd:" "$OUT/$tag.log" 2>/dev/null | head -6
