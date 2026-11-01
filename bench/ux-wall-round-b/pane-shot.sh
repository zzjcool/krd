#!/bin/bash
# usage: shot.sh COLSxROWS
set -e
S="$REX_SESSION"
B=$(cat /tmp/krd-overnight/ux-wall/block.txt)
C=${1%x*}; R=${1#*x}
rex api call -s "$S" block.method "{\"block_id\":\"$B\",\"method\":\"resize\",\"args\":{\"columns\":$C,\"rows\":$R}}" >/dev/null
sleep 1.6
rex capture -s "$S" -b "$B" --trim > "/tmp/krd-overnight/ux-wall/$1.txt" 2>&1
python3 - "$1" <<'PY'
import sys
size=sys.argv[1]
d=open(f'/tmp/krd-overnight/ux-wall/{size}.txt',encoding='utf-8').read()
rows=d.split('\n')
for i,r in enumerate(rows,1):
    out=[]
    for ch in r:
        if ch=='\U0010EEEE': out.append('.')
        elif 0x300<=ord(ch)<=0x36f: out.append('')
        else: out.append(ch)
    print(f"{i:2d}|" + "".join(out).rstrip())
PY
