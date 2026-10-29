import sys, os, time, zlib, struct, base64
w, h, n = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
def mk(w,h,seed):
    rows=bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            rows.extend(((x*3+seed)%256, (y*5+seed)%256, ((x^y)+seed)%256))
    def ch(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    return (b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))
            +ch(b'IDAT',zlib.compress(bytes(rows),1))+ch(b'IEND',b''))
frames=[base64.b64encode(mk(w,h,i)).decode() for i in range(min(n,8))]
out=sys.stdout; t0=time.time(); sent=0
for i in range(n):
    d=frames[i%len(frames)]
    for j in range(0,len(d),4096):
        p=d[j:j+4096]; more=0 if j+4096>=len(d) else 1
        out.write(f"\033_Gi={1000+i},f=100,a=T,q=2,C=1,m={more};{p}\033\\")
        sent+=len(p)
    out.write("\033[1;1H")
    out.flush()
dt=time.time()-t0
print(f"\r\nframes={n} png={len(base64.b64decode(frames[0]))}B b64={len(frames[0])}B "
      f"total={sent/1e6:.2f}MB t={dt:.2f}s -> {sent/1e6/dt:.2f}MB/s  {n/dt:.1f}fps", file=sys.stderr)
