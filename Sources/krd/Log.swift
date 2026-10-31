import Foundation
import krdcore

/// While an image owns the screen, text must not go to the terminal: every line written
/// moves the cursor, and a line on the last row scrolls the grid -- which slides the tiles
/// out from under their (absolute) cell positions and shreds the picture.
enum Log {
    private static var handle: FileHandle = .standardError
    private(set) static var path: String? = nil
    /// The last few hundred lines, kept so `SIGUSR2` can put them in the report bundle without the
    /// user having to have started krd with `--debug` (issue #52). `write` is called from the frame
    /// thread, the input thread and the diagnostics timer, so the ring has a lock.
    private static let lock = NSLock()
    private static var recent: [String] = []
    private static let recentLimit = 200

    /// `--debug` normally means "I want to read the numbers", not "write them over the image",
    /// so without an explicit destination we log to a file and say where.
    static func configure(explicitPath: String?, wantsLogging: Bool) {
        guard wantsLogging else { return }
        let target = explicitPath ?? NSTemporaryDirectory() + "krd-\(getpid()).log"
        FileManager.default.createFile(atPath: target, contents: nil)
        if let h = FileHandle(forWritingAtPath: target) {
            handle = h
            path = target
        }
    }

    /// The last `lines` lines of `text`, newest last -- the log panel's window onto the file.
    ///
    /// A log file ends in a newline, and that newline does not start a line: keeping the empty string
    /// after it made the tail one entry longer than the file has, so a panel anchored at the newest
    /// line spent one of its rows on a blank (#118). Blank lines *between* lines are kept -- a log
    /// with a gap in it is telling the reader something.
    ///
    /// Pure so the rule can be tested without a file on disk: see `LogTailTests`.
    static func tail(of text: String, lines: Int) -> [String] {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.last?.isEmpty == true { all.removeLast() }
        return Array(all.suffix(max(0, lines)))
    }

    static func write(_ text: String) {
        handle.write(Data(text.utf8))
        lock.lock()
        // Split on newlines so the ring counts *lines*, not calls: a capture error ends with "\n"
        // and a stats line does too, but a "posting to pid" note does not.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            recent.append(String(line))
        }
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        lock.unlock()
    }

    static var recentLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recent
    }
}
