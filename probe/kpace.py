import sys,time,zlib,struct,base64
w,h,n,fps=int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3]),float(sys.argv[4])
def mk(w,h,seed):
    rows=bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            rows.extend((((x+seed)*3)%256,((y+seed)*5)%256,((x*y+seed))%256))
    def ch(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    return (b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))
            +ch(b'IDAT',zlib.compress(bytes(rows),1))+ch(b'IEND',b''))
frames=[base64.b64encode(mk(w,h,i)).decode() for i in range(n)]
out=sys.stdout; t0=time.time()
for i,d in enumerate(frames):
    for j in range(0,len(d),4096):
        p=d[j:j+4096]; more=0 if j+4096>=len(d) else 1
        out.write(f"\033_Gi={2000+i%4},f=100,a=T,q=2,C=1,m={more};{p}\033\\")
    out.write("\033[1;1H"); out.flush()
    lag=t0+i/fps-time.time()
    if lag>0: time.sleep(lag)
dt=time.time()-t0
print(f"\r\n{w}x{h} {n} frames @{fps}fps target={n/fps:.2f}s actual={dt:.2f}s "
      f"-> {'KEEPS UP' if dt < n/fps*1.15 else 'BACKPRESSURE'} ({n/dt:.1f}fps)",
      file=sys.stderr)
