// The cost of one 1 s wall tick on a completely static screen, measured at the primitive level.
//
// `Desk.refreshWall(force:)` (Sources/krd/main.swift:1248) runs this on every tick, before it is
// allowed to decide that nothing changed:
//
//   main.swift:1255   let tty = TermGeometry.read()               -> ioctl(TIOCGWINSZ)   (Geometry.swift:27)
//   main.swift:1258   let model = options.demo ? demoModel()
//                                             : WallSource.model() -> CGWindowListCopyWindowInfo + NSWorkspace
//                                                                                          (WallSource.swift:97,42,27)
//   main.swift:1259   guard force || model != wallModel ...       -> the compare can only run *after*
//                                                                    the model was already recomputed
//
// So the fingerprint that decides "nothing changed" is itself the expensive part. This probe times
// each primitive on its own; the whole-tick number comes from tick_harness.swift, which runs the
// real binary under a pty and reads its CPU from proc_pid_rusage.
//
// Two channels per row, and they are not the same number:
//   * CPU (CLOCK_PROCESS_CPUTIME_ID, the same accounting proc_pid_rusage reports) - what the machine
//     burns, comparable to the product run.
//   * wall (CLOCK_UPTIME_RAW) - how long the caller is stuck, i.e. how long the main queue is
//     blocked on the window server, which on wall mode is the queue that also dispatches input.
//
// Build + run (no product build needed, no krdcore import):
//   swiftc -O bench/wall-tick/tick_cost.swift -o /tmp/krd-overnight/bug-sweep/tick_cost
//   /tmp/krd-overnight/bug-sweep/tick_cost 200          # N iterations per row
//
// Everything is a local call into the running window server / kernel: no Screen Recording grant is
// involved (see WallSource.swift's header comment), so these are the numbers a denied-grant wall
// pays.

import AppKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - clocks

@inline(__always)
func nowNs() -> UInt64 {
    // Monotonic, sleeps excluded on Darwin, nanosecond resolution.
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

@inline(__always)
func cpuNowNs() -> UInt64 {
    // Same accounting as proc_pid_rusage (ri_user_time + ri_system_time), so a probe row is
    // directly comparable to the product's per-tick number.
    clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
}

// MARK: - one row of numbers

struct Series {
    var samples: [UInt64] = []
    var sorted: [UInt64] = []
    var empty: Bool { samples.isEmpty }
    mutating func finish() { sorted = samples.sorted() }
    private func quantile(_ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count) * q).rounded(.up)) - 1
        return Double(sorted[Swift.min(sorted.count - 1, Swift.max(0, rank))]) / 1e6
    }
    var median: Double { medianOf(sorted) }
    var p95: Double { quantile(0.95) }
    var min: Double { Double(sorted.first ?? 0) / 1e6 }
    var max: Double { Double(sorted.last ?? 0) / 1e6 }
    var mean: Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.reduce(0, &+)) / Double(samples.count) / 1e6
    }
}

func medianOf(_ sorted: [UInt64]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return Double(sorted[sorted.count / 2]) / 1e6
}

struct Row {
    let name: String
    let note: String
    var wall = Series()
    var cpu = Series()
    var n: Int { wall.samples.count }
    var cpuMedian: Double { cpu.median }
    var cpuP95: Double { cpu.p95 }
    var wallMedian: Double { wall.median }
    var wallP95: Double { wall.p95 }
}

/// Ticks in an hour at one tick per second: how much a per-tick cost compounds.
let ticksPerHour = 3600.0

/// `body` returns a checksum: something the optimiser cannot delete the call for. This probe is
/// built -O, and a discarded result would measure an optimisation, not a syscall.
func measure(_ name: String, _ note: String, iterations: Int, pace: Double = 0,
             _ body: () -> Int) -> Row {
    var row = Row(name: name, note: note)
    row.wall.samples.reserveCapacity(iterations)
    row.cpu.samples.reserveCapacity(iterations)
    var checksum = 0
    for _ in 0..<Swift.min(20, iterations) { checksum &+= body() }  // warm: first call reaches the window server
    for _ in 0..<iterations {
        // The sleep is *outside* the timed region: this measures the call at a tick's cadence, not
        // the cadence itself.
        if pace > 0 { Thread.sleep(forTimeInterval: pace) }
        let w0 = nowNs(), c0 = cpuNowNs()
        checksum &+= body()
        let c1 = cpuNowNs(), w1 = nowNs()
        row.wall.samples.append(w1 &- w0)
        row.cpu.samples.append(c1 &- c0)
    }
    if checksum == Int.min { print("") }  // keep the checksum alive; never true
    row.wall.finish()
    row.cpu.finish()
    return row
}

// MARK: - a pty, so TIOCGWINSZ answers like it does under --wall

struct PTY {
    let master: Int32
    let slave: Int32
    let path: String
}

func openPTY(rows: UInt16 = 50, cols: UInt16 = 200,
             xpixel: UInt16 = 1600, ypixel: UInt16 = 1000) -> PTY? {
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    guard master >= 0 else { return nil }
    guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
        close(master)
        return nil
    }
    let path = String(cString: name)
    let slave = open(path, O_RDWR | O_NOCTTY)
    guard slave >= 0 else { close(master); return nil }
    // A real pty grid, so the ioctl answer is a number and not zero: TermGeometry.read() treats
    // ws_col == 0 as "this fd is not a terminal" and falls through to another fd.
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: xpixel, ws_ypixel: ypixel)
    _ = ioctl(slave, TIOCSWINSZ, &ws)
    return PTY(master: master, slave: slave, path: path)
}

/// `TermGeometry.read()`, copied from Sources/krd/Geometry.swift:27-48 so the fallback chain is
/// measured as written (it is what a tick pays when stdout is not the pty).
func termGeometryReadChain() -> Int {
    var ws = winsize()
    var ok = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0
    if !ok || ws.ws_col == 0 {
        ok = ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0
    }
    if !ok || ws.ws_col == 0, let tty = fopen("/dev/tty", "r") {
        ok = ioctl(fileno(tty), TIOCGWINSZ, &ws) == 0
        fclose(tty)
    }
    let cols = ok ? max(Int(ws.ws_col), 1) : 80
    let rows = ok ? max(Int(ws.ws_row), 1) : 24
    return cols &* 31 &+ rows
}

// MARK: - the primitives WallSource.model() is made of

/// WallSource.windows() -> one line of it: the window-server call plus the NSArray bridge that
/// turns 24 dictionaries into Swift dictionaries (`as? [[String: Any]]`, WallSource.swift:43).
func cgWindowList() -> Int {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    var sum = list.count
    for entry in list {
        if let n = entry["kCGWindowNumber"] as? NSNumber { sum &+= n.intValue }
    }
    return sum
}

/// The same call with the array *not* bridged: CFArrayGetCount reads the count out of the CFArray
/// without turning 24 NSDictionaries into 24 Swift Dictionaries. The difference against
/// `cgWindowList()` is the price of the bridge on its own.
func cgWindowListRaw() -> Int {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) else { return 0 }
    let count = CFArrayGetCount(list)
    let first = CFArrayGetValueAtIndex(list, 0)
    return count &+ (first == nil ? 0 : 1)
}

/// WallSource.regularPIDs() -> NSWorkspace.shared.runningApplications, asked every tick, then
/// walked to pick the Dock apps (activationPolicy == .regular).
func runningApps() -> Int {
    var sum = 0
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        sum &+= Int(app.processIdentifier)
    }
    return sum
}

/// The other half of WallSource.model(): WallSource.displays() -> NSScreen.screens plus the
/// per-screen deviceDescription lookup and CGDisplayIsMain probe, mapped into WallDisplay values.
func screens() -> Int {
    let list = NSScreen.screens
    var sum = list.count
    for (index, screen) in list.enumerated() {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
        sum &+= index &+ Int(id & 0xff)
        if id != 0, CGDisplayIsMain(id) != 0 { sum &+= 1 }
        sum &+= Int(screen.frame.size.width.rounded())
        sum &+= screen.localizedName.count
    }
    return sum
}

// MARK: - run

let iterations = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 200) : 200
// The paced rows sleep ~1 s between samples, so they get their own (smaller) count.
let pacedIterations = Swift.max(10, iterations / 10)
let pty = openPTY()
if pty == nil {
    FileHandle.standardError.write(Data("tick_cost: could not open a pty; TIOCGWINSZ rows will be skipped\n".utf8))
}

var rows = [Row]()

rows.append(measure("CGWindowListCopyWindowInfo, unbridged", "WallSource.swift:42 · call only",
                    iterations: iterations) { cgWindowListRaw() })
rows.append(measure("CGWindowListCopyWindowInfo + bridge", "WallSource.swift:42-43 · per tick",
                    iterations: iterations) { cgWindowList() })
rows.append(measure("NSWorkspace.runningApplications", "WallSource.swift:27 · per tick",
                    iterations: iterations) { runningApps() })
rows.append(measure("NSScreen.screens + deviceDescription", "WallSource.swift:52 · per tick",
                    iterations: iterations) { screens() })

if let pty {
    rows.append(measure("ioctl(TIOCGWINSZ) on a pty", "Geometry.swift:29 · per tick",
                        iterations: iterations) {
        var ws = winsize()
        return Int(ioctl(pty.slave, TIOCGWINSZ, &ws)) &+ Int(ws.ws_col)
    })
    // The chain as written, with stdout on the pty: this is the --wall case (one ioctl, no fallback).
    let saved = dup(STDOUT_FILENO)
    dup2(pty.slave, STDOUT_FILENO)
    rows.append(measure("TermGeometry.read() chain, stdout=pty", "Geometry.swift:27 · per tick",
                        iterations: iterations) { termGeometryReadChain() })
    if saved >= 0 { dup2(saved, STDOUT_FILENO); close(saved) }
}

// The chain as written with no tty on stdout/stdin: the fallback walk (/dev/tty opened per tick).
rows.append(measure("TermGeometry.read() chain, no tty", "Geometry.swift:27 · worst case",
                    iterations: iterations) { termGeometryReadChain() })

// The model() half of a tick, as far as it can be reproduced without krdcore: displays() +
// windows() *including* the regularPIDs() walk, which is what WallSource.model() does. A lower
// bound on model(): WindowOrder.recent's dictionary filtering is measured in the product run.
rows.append(measure("displays()+windows() (no WindowOrder)", "lower bound on model()",
                    iterations: iterations) { screens() &+ cgWindowList() &+ runningApps() })
rows.append(measure("displays()+windows() at 1 s cadence", "lower bound on model(), paced",
                    iterations: pacedIterations, pace: 1.0) {
    screens() &+ cgWindowList() &+ runningApps()
})

// MARK: - report

func row(_ name: String) -> Row? { rows.first { $0.name == name } }

var out = ""
out += "krd wall idle tick — primitive costs\n"
out += "host: \(ProcessInfo.processInfo.operatingSystemVersionString) · \(NSScreen.screens.count) screens · "
out += "\(NSWorkspace.shared.runningApplications.count) running apps · N=\(iterations) per row, "
out += "N=\(pacedIterations) for paced rows\n"
if let pty { out += "pty: \(pty.path) 200x50 cells, 1600x1000 px\n" }
out += "\n"
out += "| measurement | source | CPU median ms | CPU p95 ms | wall median ms | wall p95 ms | CPU s/hour at 1 tick/s |\n"
out += "|---|---|---:|---:|---:|---:|---:|\n"
for r in rows {
    out += String(format: "| %@ | %@ | %.4f | %.4f | %.4f | %.4f | %.2f |\n",
                  r.name, r.note, r.cpuMedian, r.cpuP95, r.wallMedian, r.wallP95,
                  r.cpuMedian * ticksPerHour / 1000.0)
}

let ioctlCPU = row("TermGeometry.read() chain, stdout=pty")?.cpuMedian ?? 0
let cgCPU = row("CGWindowListCopyWindowInfo + bridge")?.cpuMedian ?? 0
let modelCPU = row("displays()+windows() (no WindowOrder)")?.cpuMedian ?? 0
let modelPacedCPU = row("displays()+windows() at 1 s cadence")?.cpuMedian ?? 0
let modelPacedWall = row("displays()+windows() at 1 s cadence")?.wallMedian ?? 0
out += "\n"
out += String(format: "model() lower bound: %.4f ms CPU/tick back to back, %.4f ms CPU/tick at the wall's 1 s cadence\n",
              modelCPU, modelPacedCPU)
out += String(format: "CGWindowList alone: %.4f ms CPU/tick · ioctl: %.5f ms CPU/tick\n", cgCPU, ioctlCPU)
out += String(format: "=> idle-tick CPU while nothing changed >= %.4f ms/tick, %.2f s of CPU per hour of wall time\n",
              modelPacedCPU + ioctlCPU, (modelPacedCPU + ioctlCPU) * ticksPerHour / 1000.0)
out += String(format: "   and it blocks the caller for %.4f ms of wall time per paced tick, %.2f%% of every second\n",
              modelPacedWall, modelPacedWall / 1000.0 * 100.0)
out += "   (real model() also runs WindowOrder.recent over every dictionary, and the product run in\n"
out += "    tick_harness.swift pays for it; that run is the authoritative per-tick number)\n"

var json = "{\n"
json += "  \"iterations\": \(iterations),\n"
json += "  \"paced_iterations\": \(pacedIterations),\n"
json += "  \"windows_on_screen\": \(((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])?.count ?? 0)),\n"
json += "  \"running_apps\": \(NSWorkspace.shared.runningApplications.count),\n  \"screens\": \(NSScreen.screens.count),\n"
json += "  \"rows\": [\n"
json += rows.map { r in
    String(format: "    {\"name\": \"%@\", \"n\": %d, \"cpu_median_ms\": %.4f, \"cpu_p95_ms\": %.4f, \"wall_median_ms\": %.4f, \"wall_p95_ms\": %.4f, \"wall_min_ms\": %.4f, \"wall_max_ms\": %.4f}",
           r.name, r.n, r.cpuMedian, r.cpuP95, r.wallMedian, r.wallP95, r.wall.min, r.wall.max)
}.joined(separator: ",\n")
json += "\n  ]\n}\n"

print(out)
print(json)

if let pty { close(pty.slave); close(pty.master) }
