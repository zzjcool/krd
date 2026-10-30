import Foundation
// The exact body of Desk.readLogTail (Sources/krd/main.swift:3203).
func readLogTail(_ path: String, _ lines: Int = 12) -> [String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return Array(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)).map(String.init)
}
func tailSeek(_ path: String, _ lines: Int = 12) -> [String] {
    guard let h = FileHandle(forReadingAtPath: path) else { return [] }
    let size = (try? h.seekToEnd()) ?? 0
    let window: UInt64 = 4096
    try? h.seek(toOffset: size > window ? size - window : 0)
    guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
    return Array(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)).map(String.init)
}
for mb in [1, 5, 19, 50] {
    let path = "/tmp/krd-overnight/perf-loop/big-\(mb).log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)!
        let line = Data(String(repeating: "x", count: 60).utf8) + Data("\n".utf8)
        for _ in 0..<(mb * 1024 * 1024 / line.count) { h.write(line) }
        try? h.close()
    }
    var best = Double.infinity, bestSeek = Double.infinity
    for _ in 0..<5 {
        let t0 = Double(DispatchTime.now().uptimeNanoseconds) / 1e6
        _ = readLogTail(path)
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds) / 1e6 - t0)
        let t1 = Double(DispatchTime.now().uptimeNanoseconds) / 1e6
        _ = tailSeek(path)
        bestSeek = min(bestSeek, Double(DispatchTime.now().uptimeNanoseconds) / 1e6 - t1)
    }
    print(String(format: "%3d MB  readLogTail p50-of-5(min): %7.2f ms   seek-tail: %6.3f ms", mb, best, bestSeek))
}
