// What does one idle 1 s wall tick cost the real binary, with nothing changing on screen?
//
// `sample`-free, instrument-free: the child is started on a pty (so wall mode is the same code
// path a reader gets), the pty master is drained continuously by a background thread (a full pty
// blocks the writer - that artifact is bench/exit-latency's L1 finding), and the child's CPU time
// is read from `proc_pid_rusage` at the two ends of a measurement window. CPU delta / ticks is the
// per-tick cost; bytes on the pty in the same window are the wall's output, which on a static wall
// must be 0.
//
// Two runs make the decomposition: `--demo` replaces WallSource.model() with a constant
// (WallSource.demoModel()), so C(demo) is ioctl + the model compare + the timer; C(real) adds
// CGWindowListCopyWindowInfo + NSWorkspace + NSScreen + WindowOrder.recent. The difference is what
// re-enumerating a static screen costs.
//
//   swiftc -O bench/wall-tick/tick_harness.swift -o /tmp/krd-overnight/bug-sweep/tick_harness
//   /tmp/krd-overnight/bug-sweep/tick_harness .build/release/krd 5 30 --wall --demo
//   /tmp/krd-overnight/bug-sweep/tick_harness .build/release/krd 5 30 --wall
//
// argv: <krd binary> <settle seconds> <window seconds | probe:N> [krd args...]
//
// `probe:N` runs the tick-phase probe instead of a CPU window: it changes the pty's grid N times at
// random phases and times how long the wall takes to repaint. `TermGeometry.read()` is the only
// thing that notices a grid change without a SIGWINCH (main.swift:1255-1257), so the delay is the
// wait for the next tick - a direct measurement of the tick period, which is what makes
// "CPU / second" the same thing as "CPU / tick".

import Darwin
import Foundation

// MARK: - pty

func openPTYMaster(rows: UInt16 = 50, cols: UInt16 = 200,
                   xpixel: UInt16 = 1600, ypixel: UInt16 = 1000) -> (master: Int32, slave: Int32)? {
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
        return nil
    }
    let slave = open(String(cString: name), O_RDWR | O_NOCTTY)
    guard slave >= 0 else { close(master); return nil }
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: xpixel, ws_ypixel: ypixel)
    _ = ioctl(slave, TIOCSWINSZ, &ws)
    return (master, slave)
}

// MARK: - the drained-master counter

final class Drain {
    private let fd: Int32
    private let lock = NSLock()
    private var total = 0
    private var running = true
    private var thread: Thread?
    /// Set when the master reads EOF/EIO (the child closed its side, or died).
    private(set) var eof = false

    init(fd: Int32) { self.fd = fd }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            lock.lock()
            let go = running
            lock.unlock()
            if !go { return }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                lock.lock(); total += n; lock.unlock()
            } else if n == 0 {
                lock.lock(); eof = true; lock.unlock()
                return
            } else if errno != EINTR {
                lock.lock(); eof = true; lock.unlock()
                return
            }
        }
    }

    var bytes: Int { lock.lock(); defer { lock.unlock() }; return total }
    func stop() { lock.lock(); running = false; lock.unlock() }
}

// MARK: - child CPU

struct Usage {
    var cpu: UInt64  // user + system, ns
    var user: UInt64
    var system: UInt64
    var interruptWkups: UInt64
    var idleWkups: UInt64
}

func usage(of pid: pid_t) -> Usage? {
    var info = rusage_info_v2()
    let rc = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pid_rusage(pid, RUSAGE_INFO_V2,
                        UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
    }
    guard rc == 0 else { return nil }
    return Usage(cpu: info.ri_user_time &+ info.ri_system_time,
                 user: info.ri_user_time, system: info.ri_system_time,
                 interruptWkups: info.ri_interrupt_wkups, idleWkups: info.ri_pkg_idle_wkups)
}

func cpuNs(of pid: pid_t) -> UInt64? { usage(of: pid)?.cpu }

/// CHAR(rusage_info_v2).ri_energy_nj is not what we want here; CPU time is user + system.
func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

// MARK: - args

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: tick_harness <krd> <settle-s> <window-s> [krd args...]\n".utf8))
    exit(2)
}
let binary = args[1]
let settle = Double(args[2]) ?? 5
let probeCount = args[3].hasPrefix("probe:") ? (Int(args[3].dropFirst(6)) ?? 20) : 0
let window = probeCount > 0 ? 0 : (Double(args[3]) ?? 30)
let extra = Array(args.dropFirst(4))

guard let pty = openPTYMaster() else {
    FileHandle.standardError.write(Data("tick_harness: cannot open a pty\n".utf8))
    exit(1)
}

// MARK: - fork, exec the wall on the pty

var argv: [UnsafeMutablePointer<CChar>?] = ([binary] + extra).map { strdup($0) }
argv.append(nil)

// posix_spawn, not fork: Swift marks fork unavailable, and a new session (`POSIX_SPAWN_SETSID`)
// plus a dup2'd pty on 0/1/2 is a shell pane as far as krd can tell (its /dev/tty fallback is the
// only thing that wants a *controlling* terminal, and that path is bench/tick_cost.swift's
// "no tty on 0/1" row).
var fileActions: posix_spawn_file_actions_t?
posix_spawn_file_actions_init(&fileActions)
posix_spawn_file_actions_adddup2(&fileActions, pty.slave, 0)
posix_spawn_file_actions_adddup2(&fileActions, pty.slave, 1)
posix_spawn_file_actions_adddup2(&fileActions, pty.slave, 2)
posix_spawn_file_actions_addclose(&fileActions, pty.master)
if pty.slave > 2 { posix_spawn_file_actions_addclose(&fileActions, pty.slave) }

var attr: posix_spawnattr_t?
posix_spawnattr_init(&attr)
posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

var pid: pid_t = 0
let spawned = posix_spawn(&pid, binary, &fileActions, &attr, argv, environ)
posix_spawn_file_actions_destroy(&fileActions)
posix_spawnattr_destroy(&attr)
guard spawned == 0, pid > 0 else {
    FileHandle.standardError.write(Data("tick_harness: posix_spawn failed (\(spawned))\n".utf8))
    exit(1)
}
close(pty.slave)
try? "\(pid)".write(toFile: "/tmp/krd-overnight/bug-sweep/wall.pid", atomically: true, encoding: .utf8)

let drain = Drain(fd: pty.master)
drain.start()

// MARK: - settle, then measure

Thread.sleep(forTimeInterval: settle)

if probeCount > 0 {
    // Tick-phase probe: alternate the pty grid, and time the repaint that follows. A repaint means
    // the wall noticed, and with no SIGWINCH handler in play the only path that can notice is
    // refreshWall's per-tick `TermGeometry.read()` (main.swift:1255) -> the delay is [0, period).
    var delays: [Double] = []
    var cols: UInt16 = 200
    for _ in 0..<probeCount {
        Thread.sleep(forTimeInterval: 0.35 + Double.random(in: 0...0.6))
        let before = drain.bytes
        cols = cols == 200 ? 201 : 200
        var ws = winsize(ws_row: 50, ws_col: cols, ws_xpixel: 1600, ws_ypixel: 1000)
        _ = ioctl(pty.master, TIOCSWINSZ, &ws)
        let t0 = nowNs()
        var waited = 0.0
        while drain.bytes == before && waited < 5.0 {
            Thread.sleep(forTimeInterval: 0.002)
            waited = Double(nowNs() - t0) / 1e9
        }
        if drain.bytes > before { delays.append(waited) }
    }
    kill(pid, SIGTERM); Thread.sleep(forTimeInterval: 0.5); kill(pid, SIGKILL)
    drain.stop()
    let sorted = delays.sorted()
    func q(_ v: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * v))]
    }
    print("tick-phase probe: \(probeCount) grid changes, \(delays.count) repaints observed")
    print(String(format: "  delay to repaint after the grid change: min %.3f s, median %.3f s, p95 %.3f s, max %.3f s",
                 sorted.first ?? 0, q(0.5), q(0.95), sorted.last ?? 0))
    print("  a 1 s tick puts every delay in [0, 1); a throttled timer puts them in [0, period)")
    print(delays.map { String(format: "%.3f", $0) }.joined(separator: " "))
    let json: [String: Any] = ["probe": "tick-phase", "n": probeCount, "repaints": delays.count,
                               "delays_s": delays]
    if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print("JSON " + text)
    }
    exit(0)
}
guard cpuNs(of: pid) != nil else {
    FileHandle.standardError.write(Data("tick_harness: the child is gone before the window (exit?)\n".utf8))
    drain.stop()
    kill(pid, SIGKILL)
    exit(1)
}

let usageStart = usage(of: pid)!
let bytesStart = drain.bytes
let tStart = nowNs()
Thread.sleep(forTimeInterval: window)
let usageEnd = usage(of: pid) ?? usageStart
let bytesEnd = drain.bytes
let elapsed = Double(nowNs() - tStart) / 1e9
let cpuStart = usageStart.cpu
let cpuEnd = usageEnd.cpu

let alive = cpuNs(of: pid) != nil
if alive { kill(pid, SIGTERM); Thread.sleep(forTimeInterval: 0.8); kill(pid, SIGKILL) }
drain.stop()

let ticks = elapsed  // one timer, repeating: 1 s
let perTickMs = Double(cpuEnd &- cpuStart) / 1e6 / ticks
let perTickBytes = Double(bytesEnd - bytesStart) / ticks
let logPath = NSTemporaryDirectory() + "krd-\(pid).log"
let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "(no log)"
let logLines = log.split(separator: "\n").map(String.init)

var out = ""
out += "run: krd \(extra.joined(separator: " "))\n"
out += "  child pid \(pid), pty 200x50 cells 1600x1000 px, settle \(settle)s, window \(String(format: "%.2f", elapsed))s\n"
out += String(format: "  CPU in window: %.3f ms over %.0f ticks -> %.4f ms/tick, pty bytes in window: %d (%.2f B/tick)\n",
              Double(cpuEnd &- cpuStart) / 1e6, ticks, perTickMs, bytesEnd - bytesStart, perTickBytes)
out += "  wakeups in window: \(usageEnd.interruptWkups &- usageStart.interruptWkups) interrupt, "
out += "\(usageEnd.idleWkups &- usageStart.idleWkups) idle-package  (a 1 s timer that fires every second: ~\(Int(ticks)) interrupt wakeups)\n"
out += "  CPU split: user \(String(format: "%.3f", Double(usageEnd.user &- usageStart.user) / 1e6)) ms, "
out += "system \(String(format: "%.3f", Double(usageEnd.system &- usageStart.system) / 1e6)) ms\n"
out += "  child still alive when measured: \(alive ? "yes" : "NO")\n"
out += "  log: \(logPath) (\(logLines.count) lines)\n"
for line in logLines.prefix(12) { out += "    | \(line)\n" }
print(out)

// One machine-readable line per run, for the bench table.
let json: [String: Any] = [
    "args": extra, "pid": Int(pid), "ticks": ticks, "cpu_ms": Double(cpuEnd &- cpuStart) / 1e6,
    "ms_per_tick": perTickMs, "bytes": bytesEnd - bytesStart, "bytes_per_tick": perTickBytes,
    "alive": alive, "log": logPath,
    "interrupt_wkups": Int(usageEnd.interruptWkups &- usageStart.interruptWkups),
    "idle_wkups": Int(usageEnd.idleWkups &- usageStart.idleWkups),
    "user_ms": Double(usageEnd.user &- usageStart.user) / 1e6,
    "system_ms": Double(usageEnd.system &- usageStart.system) / 1e6
]
if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
   let text = String(data: data, encoding: .utf8) {
    print("JSON " + text)
}
