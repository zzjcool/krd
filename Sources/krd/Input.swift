import Foundation
import CoreGraphics

private enum Keys {
    static let enter: CGKeyCode = 36
    static let tab: CGKeyCode = 48
    static let space: CGKeyCode = 49
    static let backspace: CGKeyCode = 51
    static let esc: CGKeyCode = 53
    static let forwardDelete: CGKeyCode = 117
    static let home: CGKeyCode = 115
    static let end: CGKeyCode = 119
    static let pageUp: CGKeyCode = 116
    static let pageDown: CGKeyCode = 121
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126
    static let f: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// US/ANSI virtual key codes for unshifted characters.
    static let map: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50, " ": space
    ]

    /// Shifted symbol -> the key you actually press.
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
    ]
}

/// Reads terminal input from stdin and injects it into the captured surface via CGEvent.
final class InputReader {
    private let currentViewport: () -> Viewport
    private let onQuit: () -> Void
    private let dryRun: Bool
    /// With --debug every recognised event is logged, so "nothing happens" can be split
    /// into "the terminal never sent it" vs "the click went to the wrong place".
    var trace = false

    private func log(_ text: String) {
        Log.write("input: " + text + "\n")
    }
    private var buffer: [UInt8] = []
    private var downButton: MouseButton?
    private var clickCount = 1
    private var lastPress: (time: TimeInterval, point: CGPoint, count: Int)?
    /// Sticky: once a report carries a coordinate beyond the grid, the terminal is talking
    /// pixels (SGR-Pixels). Terminals that ignore `?1016h` keep sending cells, and then this
    /// stays false and the old mapping applies.
    private var pixelMouse = false
    private var savedTermios: termios?

    init(viewport: @escaping () -> Viewport, dryRun: Bool = false, onQuit: @escaping () -> Void) {
        self.currentViewport = viewport
        self.dryRun = dryRun
        self.onQuit = onQuit
    }

    // MARK: lifecycle

    @discardableResult
    func start() -> Bool {
        guard isatty(STDIN_FILENO) == 1 else {
            Log.write("""
            krd: input DISABLED - stdin is not a tty, so mouse/keyboard cannot work.
                     Run it over ssh with -t (ssh -t host krd ...), not ssh host krd.
                     Mouse reporting is left off, otherwise the terminal's reports would just
                     be echoed onto the screen as text.

            """)
            return false
        }
        // Only ask the terminal for mouse reports once we know we can read them back.
        ScreenWriter.writeMouseReporting(true)
        var t = termios()
        if tcgetattr(STDIN_FILENO, &t) == 0 {
            savedTermios = t
            var raw = t
            // No echo/signals/line discipline: every key belongs to the remote side.
            raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
            raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
            raw.c_oflag &= ~UInt(OPOST)
            raw.c_cflag |= UInt(CS8)
            withUnsafeMutableBytes(of: &raw.c_cc) { p in
                p[Int(VMIN)] = 1
                p[Int(VTIME)] = 0
            }
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        Thread.detachNewThread { [weak self] in self?.loop() }
        return true
    }

    func restore() {
        if let t = savedTermios {
            var copy = t
            tcsetattr(STDIN_FILENO, TCSANOW, &copy)
            savedTermios = nil
        }
    }

    // MARK: read loop

    private func loop() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready == 0 {
                // A lone ESC with nothing following it is the Esc key.
                if buffer == [0x1B] {
                    buffer.removeAll()
                    postKey(Keys.esc, [])
                }
                continue
            }
            let n = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if n <= 0 { return }
            if trace {
                let hex = chunk[0..<n].map { String(format: "%02x", $0) }.joined(separator: " ")
                log("raw \(n) bytes: \(hex)")
            }
            buffer.append(contentsOf: chunk[0..<n])
            drain()
        }
    }

    // MARK: parsing

    private func drain() {
        while let first = buffer.first {
            if first == 0x1B {
                guard let used = parseEscape() else { return }
                buffer.removeFirst(used)
                continue
            }
            if first == 0x7F || first == 0x08 {
                buffer.removeFirst(); postKey(Keys.backspace, []); continue
            }
            if first == 0x09 {
                buffer.removeFirst(); postKey(Keys.tab, []); continue
            }
            if first == 0x0A || first == 0x0D {
                buffer.removeFirst(); postKey(Keys.enter, []); continue
            }
            if first < 0x20 {
                buffer.removeFirst(); handleControl(first); continue
            }
            let length = utf8Length(first)
            if buffer.count < length { return }
            if let text = String(bytes: buffer[0..<length], encoding: .utf8) {
                handleText(text)
            }
            buffer.removeFirst(length)
        }
    }

    private func parseEscape() -> Int? {
        if buffer.count == 1 { return nil }
        switch buffer[1] {
        case 0x5B:                                  // CSI: ESC [ ... final
            var i = 2
            while i < buffer.count {
                let b = buffer[i]
                if b >= 0x40 && b <= 0x7E {
                    let params = String(bytes: buffer[2..<i], encoding: .utf8) ?? ""
                    handleCSI(params: params, final: b)
                    return i + 1
                }
                i += 1
            }
            return nil
        case 0x4F:                                  // SS3: ESC O x
            guard buffer.count >= 3 else { return nil }
            handleSS3(buffer[2])
            return 3
        default:
            if buffer[1] < 0x20 {
                postKey(Keys.esc, [])
                return 1
            }
            if let ch = String(bytes: [buffer[1]], encoding: .utf8)?.first {
                handleKey(ch, flags: [.maskAlternate])
            }
            return 2
        }
    }

    private func handleCSI(params: String, final: UInt8) {
        if params.hasPrefix("<") {
            handleMouse(params, isRelease: final == 0x6D)   // 'm' = release
            return
        }
        let numbers = params.split(separator: ";").map { Int($0) ?? 0 }
        var flags: CGEventFlags = []
        if numbers.count >= 2 {
            let mods = numbers[1] - 1
            if mods & 1 != 0 { flags.insert(.maskShift) }
            if mods & 2 != 0 { flags.insert(.maskAlternate) }
            if mods & 4 != 0 { flags.insert(.maskControl) }
            if mods & 8 != 0 { flags.insert(.maskCommand) }
        }
        let letter = Character(UnicodeScalar(final))
        switch letter {
        case "A": postKey(Keys.up, flags); case "B": postKey(Keys.down, flags)
        case "C": postKey(Keys.right, flags); case "D": postKey(Keys.left, flags)
        case "H": postKey(Keys.home, flags); case "F": postKey(Keys.end, flags)
        case "Z": postKey(Keys.tab, flags.union(.maskShift))
        case "~":
            let code = numbers.first ?? 0
            switch code {
            case 1, 7: postKey(Keys.home, flags)
            case 2: postKey(Keys.home, flags)
            case 3: postKey(Keys.forwardDelete, flags)
            case 4, 8: postKey(Keys.end, flags)
            case 5: postKey(Keys.pageUp, flags)
            case 6: postKey(Keys.pageDown, flags)
            case 11...14: postKey(Keys.f[code - 11], flags)
            case 15: postKey(Keys.f[4], flags)
            case 17...21: postKey(Keys.f[code - 12], flags)
            case 23, 24: postKey(Keys.f[code - 11], flags)
            default: break
            }
        default: break
        }
    }

    private func handleSS3(_ b: UInt8) {
        switch Character(UnicodeScalar(b)) {
        case "A": postKey(Keys.up, [])
        case "B": postKey(Keys.down, [])
        case "C": postKey(Keys.right, [])
        case "D": postKey(Keys.left, [])
        case "H": postKey(Keys.home, [])
        case "F": postKey(Keys.end, [])
        case "P": postKey(Keys.f[0], [])
        case "Q": postKey(Keys.f[1], [])
        case "R": postKey(Keys.f[2], [])
        case "S": postKey(Keys.f[3], [])
        default: break
        }
    }

    // MARK: mouse

    /// Mouse buttons, in the order SGR encodes them in the low two bits of the button code.
    /// 3 is not a button: inside a motion report it means "nothing is held".
    private enum MouseButton: Int {
        case left = 0, middle = 1, right = 2

        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .middle: return .center
            case .right: return .right
            }
        }

        func type(press: Bool) -> CGEventType {
            switch self {
            case .left: return press ? .leftMouseDown : .leftMouseUp
            case .middle: return press ? .otherMouseDown : .otherMouseUp
            case .right: return press ? .rightMouseDown : .rightMouseUp
            }
        }

        var dragType: CGEventType {
            switch self {
            case .left: return .leftMouseDragged
            case .middle: return .otherMouseDragged
            case .right: return .rightMouseDragged
            }
        }
    }

    /// Modifier bits the terminal puts in the button code (xterm's "meta" is Option on the Mac).
    private func modifiers(from b: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if b & 4 != 0 { flags.insert(.maskShift) }
        if b & 8 != 0 { flags.insert(.maskAlternate) }
        if b & 16 != 0 { flags.insert(.maskControl) }
        return flags
    }

    private func handleMouse(_ params: String, isRelease: Bool) {
        let body = params.dropFirst()                       // strip '<'
        let parts = body.split(separator: ";").compactMap { Int($0) }
        guard parts.count >= 3 else { return }
        let b = parts[0], cx = parts[1], cy = parts[2]
        let motion = (b & 32) != 0

        // A cell coordinate can never be larger than the terminal grid; anything bigger is a
        // pixel coordinate, i.e. the terminal honoured `?1016h`.
        if cx > TermGeometry.lastGrid.cols || cy > TermGeometry.lastGrid.rows {
            pixelMouse = true
        }

        let viewport = currentViewport()
        let point: CGPoint
        let spot: String
        if pixelMouse {
            guard viewport.contains(pixel: cx, cy) else {
                if !motion { downButton = nil }
                return
            }
            point = viewport.point(forPixel: cx, cy)
            spot = "px(\(cx),\(cy))"
        } else {
            guard viewport.contains(cell: cx, cy) else {
                if !motion { downButton = nil }
                return
            }
            point = viewport.point(forCell: cx, cy)
            spot = "cell(\(cx),\(cy))"
        }
        let flags = modifiers(from: b)

        if b & 64 != 0 {                                    // wheel: 64/65 vertical, 66/67 horizontal
            let kind = b & 3
            if dryRun || trace {
                log("wheel \(kind) at \(spot) -> (\(Int(point.x)),\(Int(point.y))) flags=\(flags.rawValue)")
            }
            if !dryRun { postScroll(kind, flags: flags) }
            return
        }

        let index = b & 3
        let button = MouseButton(rawValue: index) ?? MouseButton.left
        let type: CGEventType
        if motion && index == 3 {                           // 1003: pointer moving, nothing held
            type = CGEventType.mouseMoved
            downButton = nil
        } else if motion {
            type = button.dragType
            downButton = button
        } else if isRelease {
            type = button.type(press: false)
            downButton = nil
        } else {
            type = button.type(press: true)
            downButton = button
            clickCount = nextClickCount(for: point)
        }
        if dryRun || trace {
            log("mouse \(Self.name(type)) at \(spot) -> (\(Int(point.x)),\(Int(point.y))) "
                + "click=\(clickCount) flags=\(flags.rawValue)")
            if dryRun { return }
        }
        postMouse(type, button: button, at: point, flags: flags)
    }

    /// Double and triple clicks: same spot within half a second, like the real thing.
    private func nextClickCount(for point: CGPoint) -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        if let last = lastPress, now - last.time < 0.5,
           abs(last.point.x - point.x) < 4, abs(last.point.y - point.y) < 4 {
            let count = min(last.count + 1, 3)
            lastPress = (now, point, count)
            return count
        }
        lastPress = (now, point, 1)
        return 1
    }

    private static func name(_ type: CGEventType) -> String {
        switch type {
        case .mouseMoved: return "move"
        case .leftMouseDown: return "left-down"
        case .leftMouseUp: return "left-up"
        case .leftMouseDragged: return "left-drag"
        case .rightMouseDown: return "right-down"
        case .rightMouseUp: return "right-up"
        case .rightMouseDragged: return "right-drag"
        case .otherMouseDown: return "middle-down"
        case .otherMouseUp: return "middle-up"
        case .otherMouseDragged: return "middle-drag"
        default: return "type(\(type.rawValue))"
        }
    }

    // MARK: keys

    private func handleControl(_ byte: UInt8) {
        switch byte {
        case 0x1C:                                          // Ctrl-\ : leave
            onQuit()
        case 0x00:
            postKey(Keys.space, .maskControl)
        case 0x1B:
            postKey(Keys.esc, [])
        default:
            guard byte >= 0x01, byte <= 0x1A,
                  let ch = Character(UnicodeScalar(byte + 0x60)) as Character? else { return }
            handleKey(ch, flags: [.maskControl])
        }
    }

    private func handleText(_ text: String) {
        for ch in text {
            handleKey(ch, flags: [])
        }
    }

    private func handleKey(_ ch: Character, flags: CGEventFlags) {
        if let code = Keys.map[ch] {
            postKey(code, flags)
            return
        }
        if let base = Keys.shifted[ch], let code = Keys.map[base] {
            postKey(code, flags.union(.maskShift))
            return
        }
        if ch.isUppercase, let code = Keys.map[Character(ch.lowercased())] {
            postKey(code, flags.union(.maskShift))
            return
        }
        postUnicode(ch, flags)
    }

    private func postKey(_ code: CGKeyCode, _ flags: CGEventFlags) {
        if dryRun || trace { log("key code=\(code) flags=\(flags.rawValue)") }
        if dryRun { return }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private func postUnicode(_ ch: Character, _ flags: CGEventFlags) {
        var utf16 = Array(String(ch).utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.flags = flags
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)
        }
    }

    private func postMouse(_ type: CGEventType, button: MouseButton, at point: CGPoint, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button.cgButton) else { return }
        // Always set the flags from the report itself. A CGEvent built with a nil source inherits
        // the session's modifier state, and postKey() sets .maskControl on the events it posts, so
        // a stale Control would turn every later click into a Control-click -- i.e. a right click
        // that pops a context menu and refuses to drag anything.
        event.flags = flags
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        default:
            break
        }
        event.post(tap: .cghidEventTap)
    }

    /// `kind` follows xterm: 64 up, 65 down, 66 left, 67 right.
    private func postScroll(_ kind: Int, flags: CGEventFlags) {
        let vertical = kind < 2
        let sign: Int32 = kind % 2 == 0 ? 1 : -1            // the even codes are up / left
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                 wheel1: vertical ? sign : 0,
                                 wheel2: vertical ? 0 : sign,
                                 wheel3: 0) else { return }
        event.flags = flags                                 // same reason as postMouse
        event.post(tap: .cghidEventTap)
    }

    private func utf8Length(_ first: UInt8) -> Int {
        switch first {
        case 0x00..<0x80: return 1
        case 0xC0..<0xE0: return 2
        case 0xE0..<0xF0: return 3
        default: return 4
        }
    }
}
