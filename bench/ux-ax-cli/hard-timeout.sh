#!/bin/bash
# k.sh SECONDS cmd... : hard-timeout wrapper (macOS has no `timeout`)
secs=$1; shift
o=$(mktemp); e=$(mktemp)
perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@" >"$o" 2>"$e"
rc=$?
printf '### %s\n    rc=%s out=%sB err=%sB\n' "$*" "$rc" "$(wc -c <"$o"|tr -d ' ')" "$(wc -c <"$e"|tr -d ' ')"
sed -n '1,14p' "$o" | sed 's/^/    OUT| /'
sed -n '1,14p' "$e" | sed 's/^/    ERR| /'
rm -f "$o" "$e"
