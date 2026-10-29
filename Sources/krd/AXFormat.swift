// The pure half of `krd ax`: turning accessibility nodes into text an agent can read.
//
// Nothing here talks to the accessibility API or to a terminal, so it is covered by
// Tests/krdTests/AXFormatTests.swift instead of needing a permission prompt.

import CoreGraphics
import Foundation

/// One node, already reduced to what a model gets to see.
struct AXNode {
    var ref: String
    var depth: Int
    var role: String        // full AX role, e.g. "AXButton"
    var name: String        // title / description, already sanitized
    var detail: String      // `value="…"` or `id=…`, already sanitized and empty when absent
    var frame: CGRect?
    var actions: [String]   // "press", "showmenu", …
}

enum AXText {
    /// Roles a model can act on. Kept in sync with what macOS 14+ actually exposes:
    /// this is the `snapshot -i` filter of docs/research-ax-text-channel.md §2.3.
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXLink", "AXSlider", "AXTabGroup", "AXMenuItem", "AXComboBox",
        "AXSearchField", "AXIncrementor", "AXDisclosureTriangle", "AXSegmentedControl",
        "AXColorWell", "AXDateField", "AXLevelIndicator", "AXValueIndicator",
    ]

    /// Structure. Emitted only when the node carries a name, otherwise it is noise:
    /// a Finder window is 56 AXRow + 26 AXCell nodes whose parents already say where they are.
    static let structuralRoles: Set<String> = [
        "AXGroup", "AXSplitter", "AXImage", "AXRow", "AXColumn", "AXCell", "AXUnknown",
        "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXLayoutItem", "AXLayoutArea", "AXBrowser",
    ]

    /// Lowest depth always shown, even when empty, so the reader sees the skeleton.
    static let alwaysShowRoles: Set<String> = ["AXWindow", "AXSheet", "AXDialog", "AXWebArea"]

    /// Replace anything a terminal would interpret, then clamp.
    ///
    /// Two reasons this is not optional: window titles come from arbitrary documents
    /// (SECURITY.md §"untrusted titles"), and a raw ESC in the stream would repaint the
    /// caller's terminal instead of being printed.
    static func sanitize(_ raw: String, limit: Int = 80) -> String {
        var out = String()
        out.reserveCapacity(min(raw.count, limit + 1))
        var taken = 0
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let unsafe = value < 0x20                       // C0, including ESC and newline
                || (0x7F...0x9F).contains(value)            // DEL + C1
                || value == 0x2028 || value == 0x2029       // line / paragraph separator
                || value == 0x202E                          // right-to-left override
            if unsafe {
                if taken >= limit {
                    out.append("…")
                    break
                }
                out.append(" ")
                taken += 1
                continue
            }
            if taken >= limit {
                out.append("…")
                break
            }
            out.unicodeScalars.append(scalar)
            taken += 1
        }
        return out
    }

    /// "AXButton" → "button". Agents read the short form; JSON keeps the full one.
    ///
    /// Sanitized first: an app may return any string as its role, and this is printed raw.
    static func shortRole(_ role: String) -> String {
        let clean = sanitize(role, limit: 24)
        let stripped = clean.hasPrefix("AX") ? String(clean.dropFirst(2)) : clean
        return stripped.isEmpty ? "unknown" : stripped.lowercased()
    }

    /// `AXPress` → `press`.
    static func shortAction(_ action: String) -> String {
        shortRole(action)
    }

    /// Whether a node earns a line.
    ///
    /// - `interactiveOnly` is the `-i` switch: action-able nodes and nothing else.
    /// - Otherwise interactive nodes plus *named* structure (a labelled group tells the
    ///   reader where they are; an unlabelled one is a wrapper).
    static func isEmittable(role: String, name: String, interactiveOnly: Bool) -> Bool {
        if alwaysShowRoles.contains(role) { return true }
        if interactiveRoles.contains(role) { return true }
        if interactiveOnly { return false }
        if structuralRoles.contains(role) { return !name.isEmpty }
        return true
    }

    /// `[120,80 64x24]`, points, top-left origin — the same space as krd's Viewport.
    static func frameText(_ frame: CGRect?) -> String {
        guard let frame, frame.width > 0, frame.height > 0 else { return "" }
        return "[\(coordinate(frame.minX)),\(coordinate(frame.minY)) "
            + "\(coordinate(frame.width))x\(coordinate(frame.height))]"
    }

    /// `Int(CGFloat)` traps on NaN, ±inf and anything outside Int's range, and the numbers come
    /// from another process. Clamp to a range that is still a screen coordinate (−1M…1M points).
    static func coordinate(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), -1_000_000), 1_000_000))
    }

    /// One line: `@e3  button  "Save"  value="hi"  [120,80 64x24]  press`.
    /// Fields that are absent are omitted, not blanked, so a wide tree stays narrow.
    static func render(_ node: AXNode) -> String {
        var parts: [String] = ["\(node.ref)", String(repeating: "  ", count: node.depth) + shortRole(node.role)]
        if !node.name.isEmpty { parts.append("\"\(node.name)\"") }
        if !node.detail.isEmpty { parts.append(node.detail) }
        let frame = frameText(node.frame)
        if !frame.isEmpty { parts.append(frame) }
        if !node.actions.isEmpty { parts.append(node.actions.joined(separator: ",")) }
        return parts.joined(separator: "  ")
    }

    /// The header a tree dump starts with; one line, comments prefixed with `#` so a
    /// `grep -v '^#'` or a model does not have to special-case it.
    static func header(app: String, window: String, index: Int, count: Int,
                       shown: Int, truncated: Bool, menuBar: Bool) -> String {
        var line = "# krd ax — \(sanitize(app, limit: 40))"
        if !window.isEmpty { line += " \"\(sanitize(window, limit: 60))\"" }
        line += " (window \(index + 1)/\(count))"
        if menuBar { line += " +menubar" }
        line += "\n# \(shown) nodes shown" + (truncated ? ", truncated" : "")
        return line
    }
}
