import Foundation
import CoreGraphics

// The window list the agent needs to address a capture.
//
// `krd ax windows` answers "which apps have windows, and what does Accessibility think of them",
// which is the right question for actions but the wrong one for pixels: `screencapture -l` wants a
// CGWindowID, and `krd ax` has no reason to know one. So the driver answers separately, in the
// coordinate space the capture uses, and the two lists are joined by app + title.

func runWindows(_ args: Args) -> Never {
    let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var rows: [[String: Any]] = []
    for entry in raw {
        guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
              let id = entry[kCGWindowNumber as String] as? Int,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.width > 40, bounds.height > 40 else { continue }
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
        if alpha < 0.05 { continue }
        rows.append([
            "id": id,
            "app": entry[kCGWindowOwnerName as String] as? String ?? "",
            "pid": entry[kCGWindowOwnerPID as String] as? Int ?? 0,
            "title": entry[kCGWindowName as String] as? String ?? "",
            "rect": [Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height)],
        ])
    }
    // Front to back is the order WindowServer gives us, which is also what a click hits first.
    let json = try! JSONSerialization.data(withJSONObject: ["windows": rows], options: [.sortedKeys])
    print(String(data: json, encoding: .utf8)!)
    exit(0)
}
