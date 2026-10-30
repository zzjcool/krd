import Foundation
import CoreGraphics
import ApplicationServices

// The hands: post real CGEvents into the machine this runs on, one gesture per process.
//
// Why a separate binary rather than `krd`: krd already posts CGEvents for a human typing into a
// terminal, but that path starts at a pty and ends in a render loop — there is no way to say
// "click at 812,340" to it. An agent needs exactly that, with no terminal in between, and it needs
// to be cheap enough to call once per observation.
//
// Coordinates are global display points, y down from the top-left of the main display — the same
// space `krd ax windows` prints and `kagent shot` produces, so a frame and a click agree.

func runInput(_ args: Args) -> Never {
    requireEventAccess()
    let source = CGEventSource(stateID: .hidSystemState)

    func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }
    func button(_ name: String) -> CGMouseButton {
        switch name {
        case "right": return .right
        case "middle": return .center
        default: return .left
        }
    }
    func mouseType(_ name: String, down: Bool) -> CGEventType {
        switch name {
        case "right": return down ? .rightMouseDown : .rightMouseUp
        case "middle": return down ? .otherMouseDown : .otherMouseUp
        default: return down ? .leftMouseDown : .leftMouseUp
        }
    }
    func dragType(_ name: String) -> CGEventType {
        switch name {
        case "right": return .rightMouseDragged
        case "middle": return .otherMouseDragged
        default: return .leftMouseDragged
        }
    }
    /// Move in small steps: an app that tracks drags only starts moving once it has seen a dragged
    /// event after the mouse-down, and a single jump is often delivered as one event a view coalesces.
    func glide(from a: CGPoint, to b: CGPoint, steps: Int, holding: String?, durationMs: Double) {
        let n = max(1, steps)
        for s in 1...n {
            let t = Double(s) / Double(n)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            if let name = holding {
                post(CGEvent(mouseEventSource: source, mouseType: dragType(name),
                             mouseCursorPosition: p, mouseButton: button(name)))
            } else {
                post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                             mouseCursorPosition: p, mouseButton: .left))
            }
            usleep(useconds_t(max(1, Int(durationMs * 1000) / n)))
        }
    }
    func settle(_ ms: Int = 60) { usleep(useconds_t(ms * 1000)) }

    let duration = args.double("duration", 400)

    switch args.verb {
    case "move":
        let p = args.point(0, args.verb)
        glide(from: p, to: p, steps: 1, holding: nil, durationMs: 0)
        settle()

    case "click", "tap":
        let p = args.point(0, args.verb)
        let name = args.opt("button", "left") ?? "left"
        let count = max(1, args.int("count", 1))
        glide(from: p, to: p, steps: 1, holding: nil, durationMs: 0)
        settle(40)
        for n in 1...count {
            let down = CGEvent(mouseEventSource: source, mouseType: mouseType(name, down: true),
                               mouseCursorPosition: p, mouseButton: button(name))
            let up = CGEvent(mouseEventSource: source, mouseType: mouseType(name, down: false),
                             mouseCursorPosition: p, mouseButton: button(name))
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            post(down)
            settle(30)
            post(up)
            settle(60)
        }

    case "down", "up":
        let p = args.point(0, args.verb)
        let name = args.opt("button", "left") ?? "left"
        glide(from: p, to: p, steps: 1, holding: nil, durationMs: 0)
        settle(40)
        post(CGEvent(mouseEventSource: source, mouseType: mouseType(name, down: args.verb == "down"),
                     mouseCursorPosition: p, mouseButton: button(name)))
        settle()

    case "drag":
        guard args.positional.count >= 4,
              let x1 = Double(args.positional[0]), let y1 = Double(args.positional[1]),
              let x2 = Double(args.positional[2]), let y2 = Double(args.positional[3]) else {
            fail(EXIT_USAGE, "drag needs x1 y1 x2 y2")
        }
        let a = CGPoint(x: x1, y: y1), b = CGPoint(x: x2, y: y2)
        let name = args.opt("button", "left") ?? "left"
        glide(from: a, to: a, steps: 1, holding: nil, durationMs: 0)
        settle(40)
        post(CGEvent(mouseEventSource: source, mouseType: mouseType(name, down: true),
                     mouseCursorPosition: a, mouseButton: button(name)))
        settle(80)
        glide(from: a, to: b, steps: args.int("steps", 24), holding: name, durationMs: duration)
        settle(60)
        post(CGEvent(mouseEventSource: source, mouseType: mouseType(name, down: false),
                     mouseCursorPosition: b, mouseButton: button(name)))
        settle()

    case "scroll":
        if args.positional.count >= 2 {
            let p = args.point(0, args.verb)
            glide(from: p, to: p, steps: 1, holding: nil, durationMs: 0)
            settle(30)
        }
        let dy = Int32(args.int("dy", 0)), dx = Int32(args.int("dx", 0))
        for _ in 0..<abs(dy) {
            post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                         wheel1: dy > 0 ? -1 : 1, wheel2: 0, wheel3: 0))
            settle(20)
        }
        for _ in 0..<abs(dx) {
            post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                         wheel1: 0, wheel2: dx > 0 ? -1 : 1, wheel3: 0))
            settle(20)
        }

    case "type":
        let text = args.positional.joined(separator: " ")
        // One event per scalar, no keycode: CGEventKeyboardSetUnicodeString is the only path that
        // types text the current layout cannot produce (Chinese, emoji, an em dash).
        for ch in text {
            for scalar in ch.unicodeScalars {
                // Surrogate pairs are sent as two events; CJK and ASCII need one each.
                var unit = UniChar(truncatingIfNeeded: scalar.value)
                var length = 1
                var pair: [UniChar] = [unit]
                if scalar.value > 0xFFFF {
                    let v = scalar.value - 0x10000
                    pair = [UniChar(0xD800 + (v >> 10)), UniChar(0xDC00 + (v & 0x3FF))]
                    length = 2
                    unit = pair[0]
                }
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: length, unicodeString: &pair)
                    post(down)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: length, unicodeString: &pair)
                    post(up)
                }
                _ = unit
                settle(6)
            }
        }

    case "key":
        guard let combo = args.positional.first else {
            fail(EXIT_USAGE, "key needs a combo, e.g. cmd+shift+a")
        }
        var parts = combo.lowercased().split(separator: "+").map(String.init)
        var key = parts.removeLast()
        var eventFlags: CGEventFlags = []
        for part in parts {
            switch part {
            case "cmd", "command", "super", "meta": eventFlags.insert(.maskCommand)
            case "shift": eventFlags.insert(.maskShift)
            case "alt", "opt", "option": eventFlags.insert(.maskAlternate)
            case "ctrl", "control": eventFlags.insert(.maskControl)
            case "fn": eventFlags.insert(.maskSecondaryFn)
            default: fail(EXIT_USAGE, "unknown modifier \(part)")
            }
        }
        let named: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        let ansi: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "`": 50,
        ]
        // Shifted punctuation: the keycode is the unshifted key plus .maskShift.
        let shifted: [String: String] = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
                                         "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
                                         "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
                                         ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
                                         "~": "`"]
        if let base = shifted[key] {
            eventFlags.insert(.maskShift)
            key = base
        }
        var code: CGKeyCode?
        if let special = named[key] {
            code = special
        } else if key.count == 1, let c = key.first {
            code = ansi[c]
        }
        guard let virtualKey = code else { fail(EXIT_USAGE, "unknown key \(key)") }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true) {
            down.flags = eventFlags
            post(down)
        }
        settle(20)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) {
            up.flags = eventFlags
            post(up)
        }

    case "sleep":
        settle(args.int("ms", 100))

    default:
        fail(EXIT_USAGE, "unknown input verb \(args.verb) "
            + "(click, move, down, up, drag, scroll, type, key, sleep)")
    }

    print("ok \(args.verb)")
    exit(0)
}
