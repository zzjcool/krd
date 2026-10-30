#!/usr/bin/env python3
# Loop-surface probe (perf audit round A). Not part of the build or the test suite: run it by hand,
# as documented in the issue it belongs to. Nothing here captures the desktop -- krd runs --mock.
import os, subprocess, sys, time, threading

def main():
    rate = float(sys.argv[1])      # bytes per second to drain
    seconds = float(sys.argv[2])   # how long to let it run
    argv = sys.argv[3:]
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL)
    start = time.time()
    chunk = max(1, int(rate * 0.05))
    total = 0
    while time.time() - start < seconds:
        t0 = time.time()
        data = p.stdout.read(chunk)
        if not data:
            break
        total += len(data)
        dt = time.time() - t0
        if dt < 0.05:
            time.sleep(0.05 - dt)
    p.terminate()
    try: p.wait(timeout=5)
    except Exception: p.kill()
    print(f"drained {total} bytes in {time.time()-start:.1f}s = {total/(time.time()-start)/1024:.1f} KB/s")

main()
