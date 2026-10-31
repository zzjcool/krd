import CoreGraphics
import Foundation

/// One display, as `krd --list` reports it.
///
/// Every field is already in the text line: `index` is what `--display` takes, `id` is the
/// `CGDirectDisplayID` the text prints, and `width`/`height` are the CoreGraphics bounds in the
/// points the text labels `pt`.
struct ListDisplay: Equatable {
    var index: Int
    var id: CGDirectDisplayID
    var width: Int
    var height: Int
    /// `CGDisplayIsMain`: the display with the menu bar and the Dock.
    var main: Bool
}

/// One window, as `krd --list` reports both formats.
///
/// `id` is the window number `--window` takes, `frame` is the global top-left-origin rectangle in
/// points (the same four numbers the text prints), and `targetable` is the inverse of the text's
/// `(backdrop — use --display N)` hint: a window that captures as a black frame (issue #24).
///
/// The two display numbers are deliberately separate, because the text and the JSON ask different
/// questions and a window can answer them differently:
///
/// - `display` (JSON) is the display whose bounds contain the frame's **centre**. That is the
///   question a caller of `--json` has: "where is this window".
/// - `backdropDisplay` (text) is the display the backdrop window **covers**, resolved through the
///   shareable list exactly as #24 left it. That is the question the hint has: "which `--display`
///   makes this capture a picture instead of a black frame". A window inset by the menu bar has
///   its centre on the display it almost covers, but a wallpaper window straddling two displays
///   does not, and the fallback list is not numbered like `--display` at all — which is why the
///   hint says `<n>` rather than a number nobody can use.
struct ListWindow: Equatable {
    var id: CGWindowID
    var app: String
    var title: String
    var frame: CGRect
    /// For JSON: the display whose bounds contain the frame's centre, nil when none does.
    var display: Int?
    /// For the text hint: the display a backdrop window covers, nil for a normal window **and**
    /// for a backdrop the shareable list could not name.
    var backdropDisplay: Int?
    var targetable: Bool
}

/// The two formats of `krd --list`, built from one set of records (issue #124).
///
/// Before this, the listing was a string builder living inside `main`: the only consumer of "what
/// displays and windows are there" was a column layout, and there was no way to ask a machine for
/// the same answer. One builder per format, from the same records, means text and JSON cannot
/// disagree about which windows exist, what order they are in, or what they are called.
///
/// Pure on purpose: no capture, no terminal, no stdout. `Tests/krdTests/ListOutputTests.swift` pins
/// both formats and the failure envelope without a screen.
enum ListOutput {
    /// The listing as the terminal has always read it — byte for byte.
    ///
    /// Issue #124 had to remove the leading `ESC _ G a=d,d=i,i=31 ESC \` *without* touching a byte
    /// of this body, so the column layout, the spacing and both backdrop-hint variants are copied
    /// from the builder this replaced.
    static func text(displays: [ListDisplay], windows: [ListWindow]) -> String {
        var text = ""
        for display in displays {
            text += "[\(display.index)] display \(display.id)  \(display.width)x\(display.height) pt\n"
        }
        for window in windows {
            var line = "    window \(window.id)  @\(Int(window.frame.minX)),\(Int(window.frame.minY)) "
                + "\(Int(window.frame.width))x\(Int(window.frame.height))  app=\(window.app)  title=\(window.title)"
            // Say it here, before somebody picks it: a backdrop window captures as a black frame,
            // which looks like krd being broken (issue #24). The number is the display the window
            // covers, from the shareable list; a backdrop it could not name prints `<n>`, because
            // a wrong `--display` is worse than an obvious "look it up yourself".
            if !window.targetable {
                if let index = window.backdropDisplay {
                    line += "  (backdrop — use --display \(index))"
                } else {
                    line += "  (backdrop — use --display <n>)"
                }
            }
            text += line + "\n"
        }
        return text
    }

    /// The same records as one JSON object on one line: `krd --list --json`.
    ///
    /// Serialized by the helper `krd ax --json` uses, so the shape a caller parses (one object,
    /// sorted keys, `ok` included) is the one already documented for this binary.
    static func json(displays: [ListDisplay], windows: [ListWindow]) -> String {
        let displayRows: [[String: Any]] = displays.map {
            ["index": $0.index, "id": Int($0.id), "width": $0.width, "height": $0.height,
             "main": $0.main]
        }
        let windowRows: [[String: Any]] = windows.map { window in
            var row: [String: Any] = [
                "id": Int(window.id),
                "app": window.app,
                "title": window.title,
                // The four numbers the text prints, not CGRect's sub-point remainder: the two
                // formats are the same digits.
                "frame": [Int(window.frame.minX), Int(window.frame.minY),
                          Int(window.frame.width), Int(window.frame.height)],
                "targetable": window.targetable,
            ]
            // `null`, not a missing key: a caller that branches on `display == null` would
            // otherwise have to tell "not on a display" from "field absent".
            row["display"] = window.display.map { $0 as Any } ?? NSNull()
            return row
        }
        return AXCommand.jsonString(["ok": true, "displays": displayRows, "windows": windowRows]) + "\n"
    }

    /// A failure a machine can read: one object on stdout, the prose on stderr, the code to exit on.
    ///
    /// The #123 envelope, unchanged (`krd ax` builds the same one in `failureOutput`): the exit
    /// code is the one text mode returns, `code` is its token, and `next` says what to do about it.
    static func failure(code: String, exit: Int32, message: String, next: String)
        -> (stdout: String, stderr: String, exit: Int32) {
        let stdout = AXCommand.jsonString(
            ["ok": false, "error": ["code": code, "exit": Int(exit), "message": message, "next": next]]
        ) + "\n"
        return (stdout: stdout, stderr: message + "\n", exit: exit)
    }

    /// A refused command line, when the caller asked for `--json`: code `usage`, status 2.
    ///
    /// `stderr` is the exact line an unparsed command line has always printed, so a human reading
    /// the failure sees no difference; only the extra object on stdout is new.
    static func usageFailure(_ message: String)
        -> (stdout: String, stderr: String, exit: Int32) {
        var output = failure(code: "usage", exit: AXExit.usage.rawValue, message: message,
                             next: "run `krd --help` for the flags, their arguments and the exit codes")
        output.stderr = "krd: \(message)\n"
        return output
    }
}
