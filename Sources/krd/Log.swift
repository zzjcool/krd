import Foundation

/// While an image owns the screen, text must not go to the terminal: every line written
/// moves the cursor, and a line on the last row scrolls the grid -- which slides the tiles
/// out from under their (absolute) cell positions and shreds the picture.
enum Log {
    private static var handle: FileHandle = .standardError
    private(set) static var path: String? = nil

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

    static func write(_ text: String) {
        handle.write(Data(text.utf8))
    }
}
