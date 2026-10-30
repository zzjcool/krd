import Foundation
import AppKit

// Which app will receive the next keystroke.
//
// This is the difference between "the check failed" and "nothing I typed reached anything": a
// synthetic keystroke goes to whatever is frontmost, not to the app an Accessibility dump is looking
// at, and those two can disagree for a whole run. A scenario that types into a text field it just
// found by ref can lose every character and still see an unchanged screen -- a failure that reads
// like a product bug.
func runFrontmost(_ args: Args) -> Never {
    let workspace = NSWorkspace.shared
    let app = workspace.frontmostApplication
    var row: [String: Any] = [
        "app": app?.localizedName ?? "",
        "bundle": app?.bundleIdentifier ?? "",
        "pid": app?.processIdentifier ?? 0,
    ]
    // The frontmost *window* is what a click or a keystroke actually goes to; the app can be active
    // while a sheet or a second window holds the keyboard.
    if let window = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
       let top = window.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }) {
        row["window"] = top[kCGWindowName as String] as? String ?? ""
        row["window_id"] = top[kCGWindowNumber as String] as? Int ?? 0
        row["window_app"] = top[kCGWindowOwnerName as String] as? String ?? ""
    }
    let json = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(String(data: json, encoding: .utf8)!)
    exit(app == nil ? 5 : 0)
}
