import sys, os, select, time, tty, termios, zlib, struct, base64, fcntl, array, glob
def mkpng(w,h):
    rows=bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w): rows.extend(((x*60)%256,(y*120)%256,128))
    def ch(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    return (b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))
            +ch(b'IDAT',zlib.compress(bytes(rows)))+ch(b'IEND',b''))
PNG=mkpng(8,4); B64=base64.b64encode(PNG).decode()
open('/tmp/kgtest.png','wb').write(PNG)
open('/tmp/tty-graphics-protocol-probe.png','wb').write(PNG)   # tempfile medium needs a known dir
fd=sys.stdin.fileno(); old=termios.tcgetattr(fd); tty.setraw(fd)
TTY=os.open('/dev/tty', os.O_WRONLY|os.O_NOCTTY)
def ask(label, seq, wait=0.7):
    os.write(TTY, seq.encode('latin1')); 
    out=b""; dl=time.time()+wait
    while time.time()<dl:
        r,_,_=select.select([fd],[],[],0.1)
        if r:
            out+=os.read(fd,4096)
            if out.endswith(b"\x1b\\"): break
    print(f"{label:34s} {out.decode('latin1').strip()[2:] if out else '(no reply)'}")
try:
    b=array.array('H',[0,0,0,0]); fcntl.ioctl(fd, termios.TIOCGWINSZ, b)
    print(f"WINSIZE rows={b[0]} cols={b[1]} xpixel={b[2]} ypixel={b[3]}  cell={b[2]/max(1,b[1]):.1f}x{b[3]/max(1,b[0]):.1f}px")
    ask("00 support query a=q",   "\033_Gi=1,s=1,v=1,a=q,t=d,f=24;AAAA\033\\")
    ask("01 transmit a=t PNG",    f"\033_Gi=50,f=100,a=t;{B64}\033\\")
    ask("02 place c,r",           "\033_Gi=50,a=p,c=8,r=4,C=1\033\\")
    ask("03 place + x,y (cells)", "\033_Gi=50,a=p,c=8,r=4,x=3,y=2,C=1\033\\")
    ask("04 place + X,Y (pixels)","\033_Gi=50,a=p,c=8,r=4,X=7,Y=9,C=1\033\\")
    ask("05 place + z index",     "\033_Gi=50,a=p,c=8,r=4,z=5,C=1\033\\")
    ask("06 anim frame a=f z=200","\033_Gi=50,a=f,f=100,z=200;"+B64+"\033\\")
    z64=base64.b64encode(zlib.compress(PNG)).decode()
    ask("07 o=z zlib png",        f"\033_Gi=51,f=100,a=t,o=z;{z64}\033\\")
    ask("08 t=f file medium",     "\033_Gi=52,f=100,a=t,t=f;/tmp/kgtest.png\033\\")
    ask("09 t=t tempfile",        "\033_Gi=53,f=100,a=t,t=t;/tmp/tty-graphics-protocol-probe.png\033\\")
    shm="/"+"kprobe%d"%os.getpid()
    raw=bytes(range(8*4*3))
    open('/tmp/shm.bin','wb').write(zlib.compress(raw))
    ask("10 f=24 raw rgb",        f"\033_Gi=54,f=24,s=8,v=4,a=t;{base64.b64encode(raw).decode()}\033\\")
    ask("11 chunk > 4096 (invalid)","\033_Gi=55,f=100,a=t,m=1;"+"A"*5000+"\033\\")
    ask("12 big chunk 4096 ok?",  "\033_Gi=56,f=100,a=t,m=1;"+"A"*4096+"\033\\")
    ask("13 delete image",        "\033_Gi=50,a=d\033\\")
    ask("14 bad base64",          "\033_Gi=57,f=100,a=t;!!!!\033\\")
finally:
    termios.tcsetattr(fd,termios.TCSADRAIN,old)
