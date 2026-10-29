import Foundation
import AppKit

/// Which halves of the clipboard bridge are on (issue #18).
///
/// `in`  — target → terminal: a copy inside the mirrored desktop becomes an OSC 52 sequence, so the
///         local terminal owns it and the local `Cmd-V` pastes it. Direction: *into* the terminal.
/// `out` — terminal → target: `Ctrl-V` in the krd session puts the terminal's clipboard on the
///         target's pasteboard and then posts `Cmd-V` to the mirrored app. Direction: *out of* the
///         terminal.
///
/// The default is `off`: a mirror that silently rewrites a machine's clipboard is a surprise, and
/// anything that leaves the target is worth an explicit flag.
struct ClipboardPolicy: Equatable, CustomStringConvertible {
    var toTerminal: Bool
    var toTarget: Bool

    static let off = ClipboardPolicy(toTerminal: false, toTarget: false)

    /// `--clipboard=off|in|out|both`. Returns nil for anything else so the caller can fail loudly
    /// instead of quietly running with clipboard sync disabled.
    init?(spec: String) {
        switch spec.lowercased() {
        case "off", "none": self = .off
        case "in", "to-terminal": self = ClipboardPolicy(toTerminal: true, toTarget: false)
        case "out", "to-target": self = ClipboardPolicy(toTerminal: false, toTarget: true)
        case "both": self = ClipboardPolicy(toTerminal: true, toTarget: true)
        default: return nil
        }
    }

    /// Direct construction, for tests and for `allowing(noInput:)`.
    init(toTerminal: Bool, toTarget: Bool) {
        self.toTerminal = toTerminal
        self.toTarget = toTarget
    }

    var isOff: Bool { !toTerminal && !toTarget }

    /// `--no-input` means "watch, do not act": the target→terminal half only reads, the
    /// terminal→target half presses keys into the mirrored machine, so it is dropped here rather
    /// than trusted to be absent from the code path.
    func allowing(noInput: Bool) -> ClipboardPolicy {
        noInput ? ClipboardPolicy(toTerminal: toTerminal, toTarget: false) : self
    }

    var description: String {
        switch (toTerminal, toTarget) {
        case (false, false): return "off"
        case (true, false): return "in"
        case (false, true): return "out"
        case (true, true): return "both"
        }
    }
}

/// OSC 52: `ESC ] 52 ; <selection> ; <base64> ST`.
///
/// Everything here is pure so the framing, the cap and the base64 handling are tested without a
/// pasteboard, a terminal, or a pty.
enum OSC52 {
    /// Payload cap. The terminal decodes the whole thing before anything is pasted, and the same
    /// stdout carries the frames; 2 MB is already ~10x a long document. Bigger clips are dropped
    /// with a log line instead of risking a stall or a partial paste (issue #18).
    static let maxBytes = 2 << 20

    /// Base64 inflates by 4/3; the input parser uses this to bound an unterminated sequence.
    static let maxEncodedBytes = (maxBytes * 4) / 3 + 16

    /// The sequence krd sends when the target's clipboard changes.
    static func encode(_ data: Data) -> String {
        "\u{1B}]52;c;\(data.base64EncodedString())\u{1B}\\"
    }

    /// The request that asks the terminal for its clipboard. Terminals that support OSC 52 reads
    /// answer with the same `52;c;<base64>` form on stdin; the ones that do not answer at all.
    static let readRequest = "\u{1B}]52;c;?\u{1B}\\"

    /// Decode the parameter string of an incoming `OSC 52 ; c ; <payload>`.
    ///
    /// nil for a `?` query (that is our own request coming back), a selection we do not handle,
    /// invalid base64, or a payload over the cap — the caller only logs the fact, never the bytes.
    static func decode(parameters: String) -> Data? {
        let parts = parameters.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "52" else { return nil }
        // `c` is the clipboard; `p`/`s`/`0`-`7` are the primary/select/ cut buffers we do not own.
        let selection = parts[1]
        guard selection.isEmpty || selection == "c" else { return nil }
        let payload = String(parts[2])
        guard !payload.isEmpty, payload != "?" else { return nil }
        guard payload.utf8.count <= maxEncodedBytes else { return nil }
        guard let data = Data(base64Encoded: payload), data.count <= maxBytes else { return nil }
        return data
    }
}

/// The target side of the bridge: `NSPasteboard.general` ↔ OSC 52.
///
/// `changeCount` polling rather than an AppKit run loop — krd has no `NSApplication`, and one
/// integer compare four times a second costs nothing next to anything that needs a run loop.
final class ClipboardBridge {
    private let policy: ClipboardPolicy
    private var lastChangeCount: Int

    init(policy: ClipboardPolicy) {
        self.policy = policy
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Returns a log line (byte count only, never the content) when something was sent, else nil.
    func poll() -> String? {
        guard policy.toTerminal else { return nil }
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count
        guard let text = board.string(forType: .string), !text.isEmpty else { return nil }

        let data = Data(text.utf8)
        guard data.count <= OSC52.maxBytes else {
            return "clipboard: \(data.count) B dropped (limit \(OSC52.maxBytes) B), target -> terminal"
        }
        ScreenWriter.writeRaw(OSC52.encode(data))
        return "clipboard: \(data.count) B target -> terminal (OSC 52)"
    }

    /// Put the terminal's clipboard on the target's pasteboard. Returns the byte count, or nil when
    /// the text is too big to be worth trying.
    func setTarget(_ text: String) -> Int? {
        let data = Data(text.utf8)
        guard data.count <= OSC52.maxBytes else { return nil }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        // Our own write must not be echoed back to the terminal on the next poll.
        lastChangeCount = board.changeCount
        return data.count
    }

    /// Announce the current change count as "already seen", for any pasteboard write krd does not
    /// want to mirror back.
    func noteSelfChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }
}
