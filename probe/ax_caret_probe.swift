// Where the insertion point sits in TextEdit, and where its text area is on screen.
//
// The verifier for issue #60's pointer test: a click on the same *terminal* pixel must reach the same
// *screen* point whatever `--scale` did to the capture, so the caret has to land at the same offset.
// One line per text area, frontmost first, because TextEdit can have more than one window open and a
// click only reaches the one in front.
//
//   swiftc -O probe/ax_caret_probe.swift -o /tmp/ax-caret && /tmp/ax-caret
//
// Needs Accessibility permission for the terminal running it (same as `krd ax`).

import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Void) {
    visit(element)
    guard depth < 40, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for child in children { walk(child, depth: depth + 1, visit) }
}

guard let app = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) else {
    print("caret: TextEdit is not running")
    exit(2)
}

var areas: [String] = []
walk(AXUIElementCreateApplication(app.processIdentifier)) { element in
    guard let role = attribute(element, kAXRoleAttribute) as? String,
          role == kAXTextAreaRole as String else { return }
    var caret = "location=none"
    if let range = attribute(element, kAXSelectedTextRangeAttribute) {
        var value = CFRange()
        if AXValueGetValue(range as! AXValue, .cfRange, &value) {
            caret = "location=\(value.location) length=\(value.length)"
        }
    }
    var frame = "frame=none"
    if let position = attribute(element, kAXPositionAttribute),
       let size = attribute(element, kAXSizeAttribute) {
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        frame = "frame=\(Int(point.x)),\(Int(point.y)) \(Int(extent.width))x\(Int(extent.height))"
    }
    areas.append("caret: \(caret) \(frame)")
}

if areas.isEmpty {
    print("caret: no text area")
} else {
    for line in areas { print(line) }
}
