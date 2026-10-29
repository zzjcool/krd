// Accessibility probe: what a headless (no-frame) krd could read, and what it costs.
//
//   swift probe/ax_probe.swift
//
// Prints, in order: the warm-up trap, the window list, a depth-limited walk of each
// window with its timing, and the same walk pruned to "interactive + named" nodes so
// the two sizes can be compared. Read-only: it never performs an action or writes a
// value. See docs/research-ax-text-channel.md.

import Cocoa
import ApplicationServices

func axError(_ e: AXError) -> String {
    switch e {
    case .success: return "ok"
    case .cannotComplete: return "cannotComplete"
    case .apiDisabled: return "apiDisabled"
    case .invalidUIElement: return "invalidUIElement"
    case .attributeUnsupported: return "attributeUnsupported"
    case .noValue: return "noValue"
    default: return "err(\(e.rawValue))"
    }
}

func value(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var out: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &out) == .success ? out : nil
}

func text(_ el: AXUIElement, _ name: String) -> String { (value(el, name) as? String) ?? "" }

func axElementAtPosition(_ x: CGFloat, _ y: CGFloat) -> (AXUIElement?, AXError) {
    var hit: AXUIElement?
    let e = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(x), Float(y), &hit)
    return (hit, e)
}

let interactive: Set<String> = [
    "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
    "AXMenuButton", "AXSlider", "AXLink", "AXTabGroup", "AXMenuItem", "AXComboBox",
    "AXSearchField", "AXIncrementor", "AXDisclosureTriangle",
]
// Structure and decoration: kept only if they carry a name.
let structural: Set<String> = [
    "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem", "AXRow", "AXColumn", "AXCell",
    "AXGroup", "AXSplitter", "AXImage", "AXUnknown",
]

let systemWide = AXUIElementCreateSystemWide()
AXUIElementSetMessagingTimeout(systemWide, 1.5)

// 1. The warm-up trap. In an ssh (Background) session the first call to any AX element
//    fails with cannotComplete even though AXIsProcessTrusted() is true; touching the
//    window server once makes the same call succeed. A headless command has to do this
//    (or retry once) before it can trust a failure as a real failure.
var focused: AnyObject?
let cold = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focused)
let windowsAtStart = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
focused = nil
let warm = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focused)
print("trusted:", AXIsProcessTrusted(), "postEvent:", CGPreflightPostEventAccess())
print("cold AX call:", axError(cold), "-> after window-server touch:", axError(warm))
if let app = focused {
    print("focused app:", text(app as! AXUIElement, kAXTitleAttribute))
}

// 2. Windows, grouped by owner. CGWindowList gives pid without Screen Recording; the
//    title comes from AX, also without it.
var owners: [(pid: pid_t, name: String)] = []
for window in windowsAtStart {
    guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
          (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
    if owners.contains(where: { $0.pid == pid }) { continue }
    owners.append((pid, (window[kCGWindowOwnerName as String] as? String) ?? "?"))
}
print("on-screen windows:", windowsAtStart.count, "owner apps:", owners.count)

// 3. Walk and time each app's first window.
var rawNodes = 0, rawChars = 0, keptNodes = 0, keptChars = 0, windows = 0
for owner in owners.prefix(8) {
    let app = AXUIElementCreateApplication(owner.pid)
    AXUIElementSetMessagingTimeout(app, 1.5)
    let list = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    guard let window = list.first else {
        print("- \(owner.name) pid=\(owner.pid): no AX windows")
        continue
    }
    windows += 1
    var nodes = 0, chars = 0, kept = 0, keptCharsHere = 0
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    let started = Date()
    while !queue.isEmpty && nodes < 4000 {
        let (el, depth) = queue.removeFirst()
        nodes += 1
        let role = text(el, kAXRoleAttribute)
        let title = text(el, kAXTitleAttribute)
        let body = text(el, kAXValueAttribute)
        chars += role.count + title.count + body.count + 16
        if interactive.contains(role) || (!title.isEmpty && !structural.contains(role)) {
            kept += 1
            keptCharsHere += role.count + title.count + body.count + 16
        }
        if depth >= 6 { continue }
        for child in (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            queue.append((child, depth + 1))
        }
    }
    let ms = Date().timeIntervalSince(started) * 1000
    rawNodes += nodes; rawChars += chars; keptNodes += kept; keptChars += keptCharsHere
    let title = String(text(window, kAXTitleAttribute).prefix(30))
    print(String(
        format: "- %@ \"%@\": %d nodes / %d ch (kept %d / %d ch) in %.0f ms (%.2f ms/node)",
        owner.name, title, nodes, chars, kept, keptCharsHere, ms, ms / Double(max(nodes, 1))))
}

print("windows walked:", windows)
print("raw:    \(rawNodes) nodes, \(rawChars) chars, ~\(rawChars / 3) tokens")
print("pruned: \(keptNodes) nodes, \(keptChars) chars, ~\(keptChars / 3) tokens")

// 4. Point -> element, the bridge a terminal click would use for teaching.
let mouse = NSEvent.mouseLocation
let flipped = CGDisplayBounds(CGMainDisplayID()).height - mouse.y
let (hit, hitError) = axElementAtPosition(mouse.x, flipped)
if let hit {
    var names: CFArray?
    _ = AXUIElementCopyActionNames(hit, &names)
    print("element at pointer:", text(hit, kAXRoleAttribute), "\"\(text(hit, kAXTitleAttribute))\"",
          "actions:", (names as? [String]) ?? [], axError(hitError))
} else {
    print("element at pointer: none (\(axError(hitError)))")
}
