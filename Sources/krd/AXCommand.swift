// `krd ax …` — the headless face of krd.
//
// No frames, no terminal modes, no Screen Recording: this reads the accessibility tree
// and prints text. It runs as its own process, so an agent drives it the same way it
// drives any other CLI: one command, one result, exit code.
//
// The preflight is deliberately first and loud. Two different failures look identical
// from the outside (an empty tree and "you never granted anything"), and the difference
// costs users an hour, so the check runs before any command does anything.
// See docs/research-ax-text-channel.md §2.2 for the measurements behind it.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum AXExit: Int32 {
    case ok = 0
    case usage = 2
    case permission = 3
    case environment = 4
    case notFound = 5
}

enum AXFailure: Error {
    case usage(String)
    case permission(String)
    case environment(String)
    case notFound(String)

    var code: AXExit {
        switch self {
        case .usage: return .usage
        case .permission: return .permission
        case .environment: return .environment
        case .notFound: return .notFound
        }
    }
}

struct AXOptions {
    var verb = ""
    var json = false
    var all = false
    var interactiveOnly = false
    var depth = 4
    var app: String?
    var pid: pid_t?
    var windowIndex = 0
    var menuBar = false
    var prompt = false
    var maxNodes = 400
}

/// What the preflight learned. Also the body of `krd ax doctor`.
struct AXProbe {
    var trusted: Bool
    var onScreenWindows: Int
    var answers: Bool
    var error: AXError
}

enum AXCommand {
    static func isInvocation(_ args: [String]) -> Bool {
        args.first == "ax"
    }

    /// Entry point. Never returns: every path ends in exit(), so the render loop and its
    /// NSApplication context are never started.
    static func run(_ args: [String]) -> Never {
        if args.contains("-h") || args.contains("--help") || args.first == "help" {
            print(usage())
            exit(AXExit.ok.rawValue)
        }
        do {
            let options = try parse(args)
            switch options.verb {
            case "windows": exit(try windows(options))
            case "tree": exit(try tree(options))
            case "screen": exit(try screen(options))
            case "doctor": exit(try doctor(options))
            default:
                throw AXFailure.usage("unknown command \"\(options.verb)\" (try `krd ax --help`)")
            }
        } catch let failure as AXFailure {
            if case .usage(let message) = failure {
                FileHandle.standardError.write(Data((message + "\n\n" + usage()).utf8))
            } else {
                FileHandle.standardError.write(Data((describe(failure) + "\n").utf8))
            }
            exit(failure.code.rawValue)
        } catch {
            FileHandle.standardError.write(Data("krd ax: \(error)\n".utf8))
            exit(AXExit.environment.rawValue)
        }
    }

    // MARK: - arguments

    static func parse(_ args: [String]) throws -> AXOptions {
        var options = AXOptions()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help", "help":
                throw AXFailure.usage("krd ax — read the Mac as text, without capturing a frame")
            case "--json": options.json = true
            case "--all": options.all = true
            case "-i", "--interactive": options.interactiveOnly = true
            case "--menubar": options.menuBar = true
            case "--prompt": options.prompt = true
            case "-d", "--depth":
                options.depth = try int(args, &i, for: arg, min: 1, max: 40)
            case "--window":
                options.windowIndex = try int(args, &i, for: arg, min: 0, max: 10_000)
            case "--pid":
                options.pid = pid_t(try int(args, &i, for: arg, min: 1, max: Int(Int32.max)))
            case "--app":
                options.app = try string(args, &i, for: arg)
            case "--max":
                options.maxNodes = try int(args, &i, for: arg, min: 1, max: 20_000)
            default:
                if arg.hasPrefix("-") {
                    throw AXFailure.usage("unknown option \"\(arg)\" (try `krd ax --help`)")
                }
                if options.verb.isEmpty {
                    options.verb = arg
                } else {
                    throw AXFailure.usage("unexpected argument \"\(arg)\" (try `krd ax --help`)")
                }
            }
            i += 1
        }
        guard !options.verb.isEmpty else {
            throw AXFailure.usage("krd ax — read the Mac as text, without capturing a frame")
        }
        if options.all && options.interactiveOnly {
            throw AXFailure.usage("--all and -i contradict each other")
        }
        return options
    }

    static func int(_ args: [String], _ i: inout Int, for flag: String, min: Int, max: Int) throws -> Int {
        guard i + 1 < args.count, let value = Int(args[i + 1]), value >= min, value <= max else {
            throw AXFailure.usage("\(flag) needs a number between \(min) and \(max)")
        }
        i += 1
        return value
    }

    static func string(_ args: [String], _ i: inout Int, for flag: String) throws -> String {
        guard i + 1 < args.count, !args[i + 1].isEmpty else {
            throw AXFailure.usage("\(flag) needs a value")
        }
        i += 1
        return args[i]
    }

    static func usage() -> String {
        """
        usage: krd ax [options] <command>

          windows                list on-screen windows (app, pid, index, title, frame)
          tree                   accessibility tree of one window
            --app <q>              app by name, bundle id, or pid (substring is enough)
            --pid <n>              …or address the app by pid
            --window <i>           window index within the app (default 0)
            -d, --depth <n>        depth limit (default 4)
            -i, --interactive      only nodes that can be acted on
            --all                  also emit unlabelled structure
            --menubar              prepend the app's menu bar
            --max <n>              node budget (default 400)
          screen                 one line per window, plus the focused element
          doctor                 check accessibility and the window server, change nothing

          --json                 machine-readable output
          --prompt               ask macOS for the Accessibility grant (opens the dialog)

        exit: 0 ok · 2 usage · 3 no accessibility permission · 4 window server unreachable
              5 nothing matched

        This command never captures a frame, so it needs Accessibility but not Screen
        Recording. See docs/research-ax-text-channel.md.
        """
    }

    // MARK: - preflight

    /// Run the checks and translate a failure into something the user can act on.
    ///
    /// The warm-up is load-bearing: a process in an ssh (Background) session gets
    /// `cannotComplete` on its first accessibility call and succeeds on a retry made
    /// after it has touched the window server. Retrying here means "cannotComplete"
    /// that reaches the user is a real problem, not startup noise.
    static func preflight(_ options: AXOptions) throws -> AXProbe {
        if options.prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        let trusted = AXIsProcessTrusted()
        let onScreen = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])?.count ?? -1

        // One process-wide timeout, set on the system-wide element: per Apple's contract
        // that is the only way to bound every element the walk creates. The default is
        // ~6 s, which turns one hung app into a hung CLI.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.5)

        var answer: AnyObject?
        var error = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &answer)
        if error == .cannotComplete {
            usleep(120_000)
            answer = nil
            error = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &answer)
        }
        let answers = error == .success || error == .noValue || error == .attributeUnsupported
        let probe = AXProbe(trusted: trusted, onScreenWindows: onScreen, answers: answers, error: error)
        try require(probe)
        return probe
    }

    static func require(_ probe: AXProbe) throws {
        if probe.answers { return }
        if !probe.trusted {
            throw AXFailure.permission(permissionText)
        }
        throw AXFailure.environment(environmentText(error: probe.error))
    }

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "krd"
    }

    static var permissionText: String {
        """
        krd ax: no Accessibility permission for \(executablePath)

        macOS records this grant against the code signature, per binary. Grant it once,
        from the Mac's own GUI terminal (a prompt started by sshd cannot be approved):

          1. System Settings > Privacy & Security > Accessibility
          2. press + and pick the binary above (Cmd-Shift-G opens a path field)
          3. quit and re-run the command

        `krd ax --prompt` asks macOS to show the dialog for you. If the pane already
        lists the binary but this still fails, the signature changed (an ad-hoc rebuild
        does that): remove the entry with − and grant it again, or start over with
        `tccutil reset Accessibility com.kkrt.macdesk`.
        """
    }

    static func environmentText(error: AXError) -> String {
        """
        krd ax: the accessibility API is not answering (\(axErrorName(error)))

        The binary is trusted, so this is the window server, not a permission: the Mac may
        be asleep or at the login window, or every app that could answer is hung.
        Run `krd ax doctor` to see which of the two it is.
        """
    }

    static func describe(_ failure: AXFailure) -> String {
        switch failure {
        case .usage(let message): return message
        case .permission(let message): return message
        case .environment(let message): return message
        case .notFound(let message): return "krd ax: \(message)"
        }
    }

    static func axErrorName(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .cannotComplete: return "cannotComplete"
        case .apiDisabled: return "apiDisabled"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notImplemented: return "notImplemented"
        case .noValue: return "noValue"
        default: return "error \(error.rawValue)"
        }
    }

    // MARK: - commands

    static func doctor(_ options: AXOptions) throws -> Int32 {
        // doctor reports instead of throwing, so it stays useful exactly when the other
        // commands cannot run at all.
        let trusted = AXIsProcessTrusted()
        let onScreen = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])?.count ?? -1
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.5)
        var answer: AnyObject?
        let first = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &answer)
        var second: AXError?
        if first == .cannotComplete {
            usleep(120_000)
            second = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &answer)
        }
        let final = second ?? first
        let answers = final == .success || final == .noValue || final == .attributeUnsupported

        var sample = "-"
        if answers, let app = asElement(answer) {
            let title = AXText.sanitize(text(app, kAXTitleAttribute), limit: 60)
            let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
            sample = "\(title.isEmpty ? "(untitled)" : title), \(windows) window(s)"
        }

        if options.json {
            let report = [
                "trusted": trusted,
                "answers": answers,
                "onScreenWindows": onScreen,
                "firstCall": axErrorName(first),
                "error": axErrorName(final),
                "sample": sample,
            ] as [String: Any]
            print(jsonString(report))
        } else {
            print("accessibility permission  \(trusted ? "granted" : "MISSING")")
            print("accessibility answers     \(answers ? "yes" : "no (\(axErrorName(final)))")")
            print("window server             \(onScreen >= 0 ? "\(onScreen) windows on screen" : "unreachable")")
            print("first call in this process \(axErrorName(first))"
                  + (second == nil ? "" : " → retry \(axErrorName(final))"))
            print("frontmost app             \(sample)")
            if !answers && !trusted {
                print("")
                print(permissionText)
            } else if !answers {
                print("")
                print(environmentText(error: final))
            }
        }
        if options.json { return AXExit.ok.rawValue }
        return answers ? AXExit.ok.rawValue : (trusted ? AXExit.environment.rawValue : AXExit.permission.rawValue)
    }

    static func windows(_ options: AXOptions) throws -> Int32 {
        _ = try preflight(options)
        let list = onScreenApps()
        var rows: [AXWindowJSON] = []
        for app in list {
            let element = AXUIElementCreateApplication(app.pid)
            for (index, window) in ((value(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []).enumerated() {
                rows.append(AXWindowJSON(
                    app: app.name, pid: app.pid, bundle: app.bundle,
                    index: index, title: text(window, kAXTitleAttribute),
                    frame: frame(window)))
            }
        }
        if options.json {
            print(jsonString(["windows": rows.map { $0.dictionary }]))
            return AXExit.ok.rawValue
        }
        if rows.isEmpty {
            print("# no on-screen windows with an accessibility tree")
            return AXExit.ok.rawValue
        }
        let appWidth = min(max(rows.map { $0.app.count }.max() ?? 10, 3), 28)
        print("# app\(String(repeating: " ", count: max(0, appWidth - 3)))  pid    win  title")
        for row in rows {
            let name = pad(AXText.sanitize(row.app, limit: appWidth), appWidth)
            let title = row.title.isEmpty ? "(untitled)" : row.title
            let frame = AXText.frameText(row.frame)
            print("\(name)  \(pad(String(row.pid), 5))  \(pad(String(row.index), 3))  "
                + "\(AXText.sanitize(title, limit: 70))\(frame.isEmpty ? "" : "  " + frame)")
        }
        return AXExit.ok.rawValue
    }

    static func screen(_ options: AXOptions) throws -> Int32 {
        _ = try preflight(options)
        let apps = onScreenApps()
        var out: [String] = []
        var jsonApps: [[String: Any]] = []
        for app in apps {
            let element = AXUIElementCreateApplication(app.pid)
            let windows = (value(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            guard !windows.isEmpty else { continue }
            var titles: [String] = []
            for window in windows {
                titles.append(AXText.sanitize(text(window, kAXTitleAttribute), limit: 60))
            }
            out.append("\(pad(AXText.sanitize(app.name, limit: 24), 24))  \(pad(String(app.pid), 5))  "
                + "\(pad("\(windows.count)w", 3))  \(titles.joined(separator: " | "))")
            jsonApps.append(["app": app.name, "pid": Int(app.pid), "windows": titles])
        }
        var focus: [String: Any] = [:]
        let system = AXUIElementCreateSystemWide()
        if let appElement = asElement(value(system, kAXFocusedApplicationAttribute)) {
            let appName = text(appElement, kAXTitleAttribute)
            var window = ""
            if let raw = asElement(value(appElement, kAXFocusedWindowAttribute)) {
                window = text(raw, kAXTitleAttribute)
            }
            var focusedRole = "", focusedTitle = ""
            if let focused = asElement(value(appElement, kAXFocusedUIElementAttribute)) {
                focusedRole = text(focused, kAXRoleAttribute)
                focusedTitle = text(focused, kAXTitleAttribute)
            }
            var focusLine = "# focus: \(AXText.sanitize(appName, limit: 40))"
            if !window.isEmpty { focusLine += " \"\(AXText.sanitize(window, limit: 50))\"" }
            if !focusedRole.isEmpty {
                focusLine += " · \(AXText.shortRole(focusedRole))"
                if !focusedTitle.isEmpty { focusLine += " \"\(AXText.sanitize(focusedTitle, limit: 40))\"" }
            }
            out.append(focusLine)
            focus = ["app": appName, "window": window, "role": focusedRole, "title": focusedTitle]
        }
        out.insert("# \(jsonApps.count) app(s) with on-screen windows", at: 0)
        if options.json {
            print(jsonString(["apps": jsonApps, "focus": focus]))
        } else {
            print(out.joined(separator: "\n"))
        }
        return AXExit.ok.rawValue
    }

    static func tree(_ options: AXOptions) throws -> Int32 {
        _ = try preflight(options)
        let app = try resolveApp(options)
        let element = AXUIElementCreateApplication(app.pid)
        let windows = (value(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard !windows.isEmpty else {
            throw AXFailure.notFound("\(AXText.sanitize(app.name, limit: 40)) has no window in the accessibility tree. "
                + "Minimised windows and windows on another Space look like this.")
        }
        guard options.windowIndex < windows.count else {
            throw AXFailure.notFound("\(AXText.sanitize(app.name, limit: 40)) has \(windows.count) window(s); "
                + "--window \(options.windowIndex) is out of range")
        }
        let window = windows[options.windowIndex]

        var reader = AXWalker(
            interactiveOnly: options.interactiveOnly && !options.all,
            emitEverything: options.all,
            maxDepth: options.depth,
            maxShown: options.maxNodes,
            maxVisited: max(options.maxNodes * 8, 2000),
            deadline: Date().addingTimeInterval(10))
        if options.menuBar, let bar = asElement(value(element, kAXMenuBarAttribute)) {
            reader.walk(root: bar, rootDepth: 0, countAsRoot: false)
        }
        reader.walk(root: window, rootDepth: 0, countAsRoot: false)

        let title = text(window, kAXTitleAttribute)
        if options.json {
            let payload = AXTreeJSON(
                app: app.name, pid: app.pid, windowIndex: options.windowIndex,
                windowCount: windows.count, windowTitle: title,
                frame: frame(window), nodes: reader.nodes,
                truncated: reader.truncated, visited: reader.visited)
            print(jsonString(payload.dictionary))
            return AXExit.ok.rawValue
        }
        print(AXText.header(
            app: app.name, window: title, index: options.windowIndex, count: windows.count,
            shown: reader.nodes.count, truncated: reader.truncated, menuBar: options.menuBar))
        for node in reader.nodes { print(AXText.render(node)) }
        return AXExit.ok.rawValue
    }

    // MARK: - app resolution

    struct RunningApp {
        var pid: pid_t
        var name: String
        var bundle: String
        var active: Bool
    }

    static func onScreenApps() -> [RunningApp] {
        let windows = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var pids: [pid_t] = []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if !pids.contains(pid) { pids.append(pid) }
        }
        return pids.compactMap { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return RunningApp(pid: pid,
                              name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
                              bundle: app.bundleIdentifier ?? "",
                              active: app.isActive)
        }
    }

    static func resolveApp(_ options: AXOptions) throws -> RunningApp {
        // Helpers, XPC services and panel hosts all answer to the same name ("Chrome"
        // matches 7 processes), so the app the user means is the regular one.
        let running = NSWorkspace.shared.runningApplications
        let regular = running.filter { $0.activationPolicy == .regular }
        let pool = regular.isEmpty ? running : regular
        if let pid = options.pid {
            guard let app = running.first(where: { $0.processIdentifier == pid }) else {
                throw AXFailure.notFound("no running application with pid \(pid)")
            }
            return RunningApp(pid: pid, name: app.localizedName ?? "pid \(pid)",
                              bundle: app.bundleIdentifier ?? "", active: app.isActive)
        }
        guard let query = options.app, !query.isEmpty else {
            throw AXFailure.usage("tree needs --app <name|bundle id|pid> or --pid <n>")
        }
        if let pid = pid_t(query), let app = pool.first(where: { $0.processIdentifier == pid }) {
            return RunningApp(pid: pid, name: app.localizedName ?? "pid \(pid)",
                              bundle: app.bundleIdentifier ?? "", active: app.isActive)
        }
        let lowered = query.lowercased()
        let exact = pool.filter {
            ($0.bundleIdentifier ?? "").lowercased() == lowered
                || ($0.localizedName ?? "").lowercased() == lowered
        }
        let partial = pool.filter {
            ($0.bundleIdentifier ?? "").lowercased().contains(lowered)
                || ($0.localizedName ?? "").lowercased().contains(lowered)
        }
        let matches = exact.isEmpty ? partial : exact
        if matches.isEmpty {
            throw AXFailure.notFound("no running application matches \"\(AXText.sanitize(query, limit: 60))\" "
                + "(try `krd ax windows`)")
        }
        if matches.count > 1 {
            let names = matches.compactMap { $0.localizedName.map { AXText.sanitize($0, limit: 40) } }
                .sorted().joined(separator: ", ")
            throw AXFailure.notFound("\"\(AXText.sanitize(query, limit: 60))\" matches \(matches.count) applications: \(names). "
                + "Use --pid to pick one (krd ax windows shows them).")
        }
        let app = matches[0]
        return RunningApp(pid: app.processIdentifier, name: app.localizedName ?? query,
                          bundle: app.bundleIdentifier ?? "", active: app.isActive)
    }

    // MARK: - accessibility helpers

    /// `value(_:_:)` can only return an AXUIElement for element attributes, but a broken app
    /// (or a CFNull where an element was promised) must not crash the CLI.
    static func asElement(_ raw: AnyObject?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var out: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success ? out : nil
    }

    static func text(_ element: AXUIElement, _ name: String) -> String {
        (value(element, name) as? String) ?? ""
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = point(value(element, kAXPositionAttribute)),
              let size = size(value(element, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func point(_ raw: AnyObject?) -> CGPoint? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let ax = raw as! AXValue
        guard AXValueGetType(ax) == .cgPoint else { return nil }
        var out = CGPoint.zero
        return AXValueGetValue(ax, .cgPoint, &out) ? out : nil
    }

    static func size(_ raw: AnyObject?) -> CGSize? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let ax = raw as! AXValue
        guard AXValueGetType(ax) == .cgSize else { return nil }
        var out = CGSize.zero
        return AXValueGetValue(ax, .cgSize, &out) ? out : nil
    }

    static func frameJSON(_ frame: CGRect) -> [String: Int] {
        ["x": AXText.coordinate(frame.minX), "y": AXText.coordinate(frame.minY),
         "width": AXText.coordinate(frame.width), "height": AXText.coordinate(frame.height)]
    }

    static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func pad(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
    }
}

// MARK: - walking

/// Breadth-first, budgeted, and attribute-batched: three IPC per node
/// (`CopyMultipleAttributeValues`, action names, children) instead of eight.
struct AXWalker {
    let interactiveOnly: Bool
    let emitEverything: Bool
    let maxDepth: Int
    let maxShown: Int
    let maxVisited: Int
    /// Wall-clock budget. A hung app costs up to 1.5 s per IPC and the walk makes three per
    /// node, so the node budget alone can take hours; this is the backstop that matters.
    let deadline: Date

    var nodes: [AXNode] = []
    var visited = 0
    var truncated = false

    private static let attributeNames: [String] = [
        kAXRoleAttribute as String, kAXTitleAttribute as String, kAXValueAttribute as String,
        kAXIdentifierAttribute as String, kAXPositionAttribute as String, kAXSizeAttribute as String,
        kAXDescriptionAttribute as String,
    ]

    mutating func walk(root: AXUIElement, rootDepth: Int, countAsRoot: Bool) {
        var queue: [(AXUIElement, Int)] = [(root, rootDepth)]
        while !queue.isEmpty {
            if Date() > deadline || visited >= maxVisited || nodes.count >= maxShown {
                truncated = true
                return
            }
            let (element, depth) = queue.removeFirst()
            visited += 1
            let values = AXCommand.multi(element, AXWalker.attributeNames)
            let role = (values[0] as? String) ?? ""
            var name = (values[1] as? String) ?? ""
            if name.isEmpty { name = (values[6] as? String) ?? "" }
            let identifier = (values[3] as? String) ?? ""
            let valueText = (values[2] as? String) ?? ""
            let origin = AXCommand.point(values[4])
            let size = AXCommand.size(values[5])
            let frame = origin.flatMap { point in size.map { CGRect(origin: point, size: $0) } }

            let cleanName = AXText.sanitize(name)
            // The first element of a walk is the thing the caller asked about (a window, a menu
            // bar). It earns a line even when its role is not in any list, otherwise a filter
            // can make a whole window look empty.
            let isRoot = element == root
            let shouldEmit = isRoot || emitEverything
                || AXText.isEmittable(role: role, name: cleanName, interactiveOnly: interactiveOnly)
            if shouldEmit {
                var detail = ""
                if !valueText.isEmpty {
                    detail = "value=\"\(AXText.sanitize(valueText, limit: 60))\""
                } else if !identifier.isEmpty {
                    detail = "id=\(AXText.sanitize(identifier, limit: 40))"
                }
                nodes.append(AXNode(
                    ref: "@e\(nodes.count + 1)",
                    depth: depth,
                    role: role,
                    name: cleanName,
                    detail: detail,
                    frame: frame,
                    actions: AXCommand.actionNames(element).map(AXText.shortAction)))
            }
            if depth >= maxDepth { continue }
            for child in (AXCommand.value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                queue.append((child, depth + 1))
            }
        }
    }
}

extension AXCommand {
    static func multi(_ element: AXUIElement, _ names: [String]) -> [AnyObject?] {
        var output: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &output)
        guard error == .success, let values = output as? [AnyObject],
              values.count == names.count else {
            return Array(repeating: nil, count: names.count)
        }
        return values.map { $0 is NSNull ? nil : $0 }
    }

    /// Standard actions only.
    ///
    /// Apps also register private actions whose names are not identifiers at all; Finder
    /// returns multi-line debug strings ("name:move previous", "selector:(null)") among
    /// them, and those used to ride into the output as raw garbage. Keeping only the
    /// `AX[A-Za-z]+` namespace drops them and keeps the column readable.
    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for name in (names as? [String]) ?? [] {
            guard name.count <= 40, name.hasPrefix("AX") else { continue }
            guard name.dropFirst(2).allSatisfy({ $0.isLetter }) else { continue }
            let short = AXText.shortAction(name)
            guard seen.insert(short).inserted else { continue }
            out.append(short)
        }
        return Array(out.prefix(6))
    }
}

// MARK: - JSON shapes

struct AXWindowJSON {
    var app: String
    var pid: pid_t
    var bundle: String
    var index: Int
    var title: String
    var frame: CGRect?

    var dictionary: [String: Any] {
        var out: [String: Any] = [
            "app": app, "pid": Int(pid), "bundle": bundle,
            "window": index, "title": AXText.sanitize(title, limit: 200),
        ]
        if let frame { out["frame"] = AXCommand.frameJSON(frame) }
        return out
    }
}

struct AXTreeJSON {
    var app: String
    var pid: pid_t
    var windowIndex: Int
    var windowCount: Int
    var windowTitle: String
    var frame: CGRect?
    var nodes: [AXNode]
    var truncated: Bool
    var visited: Int

    var dictionary: [String: Any] {
        [
            "app": app, "pid": Int(pid),
            "window": windowIndex, "windows": windowCount,
            "title": AXText.sanitize(windowTitle, limit: 200),
            "nodes": nodes.map { node -> [String: Any] in
                var out: [String: Any] = [
                    "ref": node.ref, "role": node.role, "name": node.name,
                    "depth": node.depth, "actions": node.actions,
                ]
                if !node.detail.isEmpty { out["detail"] = node.detail }
                if let frame = node.frame { out["frame"] = AXCommand.frameJSON(frame) }
                return out
            },
            "truncated": truncated, "visited": visited, "shown": nodes.count,
        ]
    }
}
