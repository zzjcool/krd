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
    /// The node exists but will not do what was asked (`press` on a static text, `set` on a
    /// read-only field), or the app accepted the write and read back something else.
    case notActionable = 6
}

enum AXFailure: Error {
    case usage(String)
    case permission(String)
    case environment(String)
    case notFound(String)
    case notActionable(String)

    var code: AXExit {
        switch self {
        case .usage: return .usage
        case .permission: return .permission
        case .environment: return .environment
        case .notFound: return .notFound
        case .notActionable: return .notActionable
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
    /// `find`: the text to look for. `press`/`set`: the ref, in `ref`.
    var query = ""
    var ref: String?
    /// `find`: restrict to one AX role (case-insensitive, `button` or `AXButton`).
    var role: String?
    /// `--dry-run`: say what the write would do and touch nothing.
    var dryRun = false
    /// `--snapshot <generation|path>`: pin a write to the dump that printed the ref.
    var snapshotID: String?
    /// `set --text`.
    var text: String?
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
            case "find": exit(try find(options))
            case "press": exit(try press(options))
            case "set": exit(try set(options))
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
            case "--role":
                options.role = try string(args, &i, for: arg)
            case "--text":
                options.text = try textValue(args, &i, for: arg)
            case "--dry-run": options.dryRun = true
            case "--snapshot":
                options.snapshotID = try string(args, &i, for: arg)
            default:
                if arg.hasPrefix("-") {
                    throw AXFailure.usage("unknown option \"\(arg)\" (try `krd ax --help`)")
                }
                if options.verb.isEmpty {
                    options.verb = arg
                } else if options.verb == "find" && options.query.isEmpty {
                    options.query = arg
                } else if (options.verb == "press" || options.verb == "set") && options.ref == nil {
                    options.ref = arg
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
        switch options.verb {
        case "find":
            guard !options.query.isEmpty || options.role != nil else {
                throw AXFailure.usage("find needs a query or --role <role>")
            }
        case "press":
            guard options.ref != nil else { throw AXFailure.usage("press needs a ref, e.g. `krd ax press @e7`") }
        case "set":
            guard options.ref != nil else { throw AXFailure.usage("set needs a ref, e.g. `krd ax set @e7 --text hello`") }
            guard options.text != nil else { throw AXFailure.usage("set needs --text <value> (use \"\" to clear)") }
        default:
            if options.text != nil || options.dryRun || options.snapshotID != nil || options.role != nil {
                throw AXFailure.usage("--text/--dry-run/--snapshot/--role only apply to find, press and set")
            }
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

    /// `--text` takes an empty string on purpose: clearing a field is a real operation.
    static func textValue(_ args: [String], _ i: inout Int, for flag: String) throws -> String {
        guard i + 1 < args.count else {
            throw AXFailure.usage("\(flag) needs a value (use \"\" to clear the field)")
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
          find <query>           nodes whose name/value/identifier/role contains <query>
            --role <r>             …and only that role (`button` or `AXButton`)
          screen                 one line per window, plus the focused element
          doctor                 check accessibility and the window server, change nothing

        Refs. Every node a dump prints has a handle (`@e7`) that stays valid across invocations:
        the dump is written under $TMPDIR/krd-ax and the ref is resolved by walking the same
        path again, verifying each step. If the UI moved on, the command fails and says so
        instead of acting on whatever sits at that index now.

          press <ref>            send AXPress (a click without the mouse)
          set <ref> --text <v>   write AXValue (`--text ""` clears a field)
          --dry-run              say what a write would do and send nothing
          --snapshot <id|path>   pin a write to the dump that printed the ref
          --app <q>              …or narrow a ref to one app

          --json                 machine-readable output
          --prompt               ask macOS for the Accessibility grant (opens the dialog)

        exit: 0 ok · 2 usage · 3 no accessibility permission · 4 window server unreachable
              5 nothing matched · 6 node refused the action, or read back something else

        Reads are the default and need no flags; press/set are explicit subcommands, and every
        write prints the state it read back afterwards. This command never captures a frame, so
        it needs Accessibility but not Screen Recording. See docs/research-ax-text-channel.md.
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
        case .notActionable(let message): return "krd ax: \(message)"
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
            includeMenus: options.menuBar,
            maxDepth: options.depth,
            maxShown: options.maxNodes,
            maxVisited: max(options.maxNodes * 8, 2000),
            deadline: Date().addingTimeInterval(10),
            refStart: AXRefStore().nextRef(bundle: app.bundle, window: options.windowIndex))
        if options.menuBar, let bar = asElement(value(element, kAXMenuBarAttribute)) {
            var menu = AXWalker(
                interactiveOnly: reader.interactiveOnly, emitEverything: reader.emitEverything,
                includeMenus: true, maxDepth: reader.maxDepth, maxShown: reader.maxShown,
                maxVisited: reader.maxVisited, deadline: reader.deadline,
                refStart: reader.refStart, root: .menuBar)
            menu.walk(root: bar, rootDepth: 0, countAsRoot: false)
            reader.entries.insert(contentsOf: menu.entries, at: 0)
            reader.visited += menu.visited
        }
        reader.walk(root: window, rootDepth: 0, countAsRoot: false)

        let title = text(window, kAXTitleAttribute)
        let generation = persist(app: app, window: title, index: options.windowIndex,
                                 count: windows.count, entries: reader.entries)
        if options.json {
            let payload = AXTreeJSON(
                app: app.name, pid: app.pid, windowIndex: options.windowIndex,
                windowCount: windows.count, windowTitle: title,
                frame: frame(window), nodes: reader.nodes,
                truncated: reader.truncated, visited: reader.visited,
                generation: generation)
            print(jsonString(payload.dictionary))
            return AXExit.ok.rawValue
        }
        print(AXText.header(
            app: app.name, window: title, index: options.windowIndex, count: windows.count,
            shown: reader.nodes.count, truncated: reader.truncated, menuBar: options.menuBar,
            refsHint: generation.map { generation in
                "refs survive this command: \(reader.nodes.first?.ref ?? "@e1")…\(reader.nodes.last?.ref ?? "")"
                    + " (krd ax press <ref> · snapshot \(generation.prefix(8)))"
            }))
        for node in reader.nodes { print(AXText.render(node)) }
        return AXExit.ok.rawValue
    }

    // MARK: - refs on disk

    /// Write the dump and return its generation, or nil when the state directory is not
    /// writable. Failing to persist must not fail the read: the tree is still the answer, it
    /// just cannot be acted on later, and the note on stderr says exactly that.
    static func persist(app: RunningApp, window: String, index: Int, count: Int,
                        entries: [AXEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let snapshot = AXSnapshot(
            schema: AXSnapshot.schema,
            generation: UUID().uuidString,
            createdAt: Date(),
            app: app.name, bundle: app.bundle, pid: app.pid,
            windowIndex: index, windowTitle: window, windowCount: count,
            nodes: entries.map { AXSnapshotNode(ref: $0.node.ref, chain: $0.chain, root: $0.root) })
        do {
            try AXRefStore().save(snapshot)
            return snapshot.generation
        } catch {
            FileHandle.standardError.write(Data(
                "krd ax: could not save refs (\(error)); `press`/`set` will not resolve them\n".utf8))
            return nil
        }
    }

    // MARK: - find

    static func find(_ options: AXOptions) throws -> Int32 {
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

        // Same filter and the same walk as `tree`, so @e7 here is the @e7 a tree dump printed:
        // a ref that means one node in a dump and another in a find is how a write path clicks
        // the wrong button. `--all` searches unlabelled structure and does renumber.
        var reader = AXWalker(
            interactiveOnly: false,
            emitEverything: options.all,
            includeMenus: options.menuBar,
            maxDepth: options.depth,
            maxShown: options.maxNodes,
            maxVisited: max(options.maxNodes * 8, 2000),
            deadline: Date().addingTimeInterval(10),
            refStart: AXRefStore().nextRef(bundle: app.bundle, window: options.windowIndex))
        if options.menuBar, let bar = asElement(value(element, kAXMenuBarAttribute)) {
            reader.walk(root: bar, rootDepth: 0, countAsRoot: false)
        }
        reader.walk(root: window, rootDepth: 0, countAsRoot: false)

        let query = options.query.lowercased()
        let wantedRole = options.role.map { AXText.shortRole($0) }
        let matches = reader.entries.filter { entry in
            if let wantedRole {
                let short = AXText.shortRole(entry.node.role)
                let full = entry.node.role.lowercased()
                if short != wantedRole && full != wantedRole { return false }
            }
            guard !query.isEmpty else { return true }
            return [entry.node.name, entry.rawValue, entry.identifier,
                    entry.node.role, AXText.shortRole(entry.node.role)]
                .contains { $0.lowercased().contains(query) }
        }
        guard !matches.isEmpty else {
            let what = options.role.map { "\($0) " } ?? ""
            throw AXFailure.notFound("no \(what)node matches \"\(AXText.sanitize(options.query, limit: 60))\" in "
                + "\(AXText.sanitize(app.name, limit: 40)) (\(reader.visited) visited, \(reader.entries.count) named). "
                + "Try a shorter query, drop --role, or raise -d/--max.")
        }

        let title = text(window, kAXTitleAttribute)
        let generation = persist(app: app, window: title, index: options.windowIndex,
                                 count: windows.count, entries: reader.entries)
        if options.json {
            var payload: [String: Any] = [
                "app": app.name, "pid": Int(app.pid), "window": options.windowIndex,
                "title": AXText.sanitize(title, limit: 200),
                "query": AXText.sanitize(options.query, limit: 80),
                "visited": reader.visited, "searched": reader.entries.count,
                "matches": matches.map { entry -> [String: Any] in
                    var out: [String: Any] = [
                        "ref": entry.node.ref, "role": entry.node.role, "name": entry.node.name,
                        "depth": entry.node.depth, "actions": entry.node.actions,
                    ]
                    if !entry.node.detail.isEmpty { out["detail"] = entry.node.detail }
                    if let frame = entry.node.frame { out["frame"] = frameJSON(frame) }
                    return out
                },
            ]
            if let generation { payload["generation"] = generation }
            print(jsonString(payload))
            return AXExit.ok.rawValue
        }
        let asked = options.query.isEmpty
            ? "role \(AXText.sanitize(options.role ?? "", limit: 24))"
            : "\"\(AXText.sanitize(options.query, limit: 60))\""
        print("# krd ax find \(asked) — \(matches.count) of "
            + "\(reader.entries.count) nodes in \(AXText.sanitize(app.name, limit: 40))"
            + (title.isEmpty ? "" : " \"\(AXText.sanitize(title, limit: 60))\""))
        if let generation {
            print("# snapshot \(generation.prefix(8)) · act on these: krd ax press <ref>")
        }
        for entry in matches { print(AXText.render(entry.node)) }
        return AXExit.ok.rawValue
    }

    // MARK: - resolving a ref

    struct ResolvedRef {
        var snapshot: AXSnapshot
        var node: AXSnapshotNode
        var element: AXUIElement
    }

    /// Turn `@e7` back into an element, or say exactly why that is not possible.
    ///
    /// Every failure here is fail-closed: the ref names one node of one dump, and if that node
    /// cannot be shown to still be the same node, the command stops. Acting on a guess is the
    /// one thing a write path must never do.
    static func resolveRef(_ options: AXOptions) throws -> ResolvedRef {
        guard let raw = options.ref else { throw AXFailure.usage("press/set need a ref") }
        guard let ref = AXRef(raw) else {
            throw AXFailure.usage("\"\(AXText.sanitize(raw, limit: 20))\" is not a ref; they look like @e7 "
                + "(print one with `krd ax tree --app <app>`)")
        }
        let store = AXRefStore()
        let snapshot: AXSnapshot
        if let pinned = options.snapshotID {
            guard let loaded = store.load(reference: pinned) else {
                throw AXFailure.notFound("no snapshot \"\(AXText.sanitize(pinned, limit: 40))\" in "
                    + "\(store.directory.path) (pass a generation id or a path to a snapshot .json)")
            }
            snapshot = loaded
        } else {
            let candidates = store.loadIndex().candidates(for: ref, app: options.app)
            if candidates.isEmpty {
                throw AXFailure.notFound("no snapshot holds \(ref). Refs are printed by a dump and kept in "
                    + "\(store.directory.path); run `krd ax tree --app <app>` (or `krd ax find <query>`) first.")
            }
            if candidates.count > 1 {
                let where_ = candidates.map { "\($0.origin) (pid \($0.pid), window \($0.window))" }
                    .joined(separator: ", ")
                throw AXFailure.usage("\(ref) is in \(candidates.count) snapshots: \(where_). "
                    + "Narrow it with --app <name> or --snapshot <generation>.")
            }
            guard let loaded = store.load(generation: candidates[0].generation) else {
                throw AXFailure.notFound("the snapshot that printed \(ref) is gone (\(candidates[0].generation)); "
                    + "re-run `krd ax tree --app <app>`")
            }
            snapshot = loaded
        }
        guard let node = snapshot.node(ref: ref.description) else {
            throw AXFailure.notFound("\(ref) is not in snapshot \(snapshot.generation) "
                + "(it has \(snapshot.nodes.count) refs); re-run the dump that printed it")
        }
        guard let first = node.chain.first else {
            throw AXFailure.notFound("\(ref) has an empty chain in snapshot \(snapshot.generation); re-dump")
        }
        // The app, not just the pid: macOS reuses pids, and a recycled pid would send the
        // action to a different program.
        guard let running = NSRunningApplication(processIdentifier: snapshot.pid),
              running.bundleIdentifier == snapshot.bundle else {
            throw AXFailure.notFound("the app that printed \(ref) (\(snapshot.app), pid \(snapshot.pid)) is not "
                + "running any more. Refs do not survive a restart: re-run `krd ax tree --app "
                + "\(AXText.sanitize(snapshot.app, limit: 30))`.")
        }
        let app = AXUIElementCreateApplication(snapshot.pid)
        let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var element: AXUIElement
        switch node.root ?? .window {
        case .menuBar:
            // A --menubar dump chains from the menu bar, which is not inside the window.
            guard let bar = asElement(value(app, kAXMenuBarAttribute)) else {
                throw AXFailure.notFound("\(ref) came from a --menubar dump, but "
                    + "\(AXText.sanitize(snapshot.app, limit: 30)) has no menu bar now; re-dump")
            }
            element = bar
        case .window:
            guard snapshot.windowIndex < windows.count else {
                throw AXFailure.notFound("window \(snapshot.windowIndex) of "
                    + "\(AXText.sanitize(snapshot.app, limit: 30)) is gone (\(windows.count) window(s) now); re-dump")
            }
            element = windows[snapshot.windowIndex]
        }
        guard signature(of: element, index: first.index).matches(first) else {
            throw AXFailure.notFound("the window \(ref) belonged to has changed since the dump "
                + "(role/title no longer match); re-dump")
        }
        let deadline = Date().addingTimeInterval(4)
        for step in node.chain.dropFirst() {
            if Date() > deadline {
                throw AXFailure.environment("resolving \(ref) ran out of time (\(node.chain.count - 1) levels); "
                    + "the app is not answering. Try again, or re-dump with -d to shorten the chain.")
            }
            element = try descend(element, step: step, ref: ref)
        }
        return ResolvedRef(snapshot: snapshot, node: node, element: element)
    }

    /// The one thing a chain step needs from a live element.
    static func signature(of element: AXUIElement, index: Int) -> AXStep {
        let values = multi(element, [kAXRoleAttribute, kAXTitleAttribute,
                                     kAXIdentifierAttribute, kAXDescriptionAttribute])
        let title = (values[1] as? String) ?? ""
        return AXStep(index: index,
                      role: (values[0] as? String) ?? "",
                      identifier: (values[2] as? String) ?? "",
                      title: title.isEmpty ? ((values[3] as? String) ?? "") : title)
    }

    /// One level. The recorded index is checked first so the common case reads one child, not
    /// all of them; a miss reads the whole level and then refuses to guess.
    static func descend(_ element: AXUIElement, step: AXStep, ref: AXRef) throws -> AXUIElement {
        let children = (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        if step.index >= 0, step.index < children.count,
           signature(of: children[step.index], index: step.index).matches(step) {
            return children[step.index]
        }
        let signatures = children.enumerated().map { signature(of: $1, index: $0) }
        switch AXRefs.descend(step, children: signatures) {
        case .same(let index), .moved(let index):
            return children[index]
        case .ambiguous(let hits):
            throw AXFailure.notFound("\(ref) is ambiguous: \(hits.count) children of one node match "
                + "\(AXText.shortRole(step.role)) \"\(AXText.sanitize(step.title, limit: 40))\" now. "
                + "Refusing to pick one; re-dump and use the ref printed by that dump.")
        case .gone:
            throw AXFailure.notFound("\(ref) is stale: no child matches \(AXText.shortRole(step.role)) "
                + "\"\(AXText.sanitize(step.title, limit: 40))\" any more (the UI changed, or the node was "
                + "retitled). Re-dump and use the new ref.")
        }
    }

    // MARK: - reading state back

    struct NodeState {
        var role = ""
        var title = ""
        var value = ""
        var enabled: Bool?
        var focused: Bool?
        var selected: Bool?

        var text: String {
            var parts: [String] = []
            parts.append("role=\(AXText.shortRole(role))")
            if !title.isEmpty { parts.append("name=\"\(AXText.sanitize(title, limit: 40))\"") }
            parts.append("value=\"\(AXText.sanitize(value, limit: 60))\"")
            if let enabled { parts.append("enabled=\(enabled)") }
            if let focused, focused { parts.append("focused") }
            if let selected, selected { parts.append("selected") }
            return parts.joined(separator: " ")
        }
    }

    static func nodeState(_ element: AXUIElement) -> NodeState? {
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute,
                     kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute]
        let values = multi(element, names)
        // A dead element answers nothing; that is not a state, it is the absence of one.
        if values.isEmpty || values.allSatisfy({ $0 is NSNull }) { return nil }
        var state = NodeState()
        state.role = (values[0] as? String) ?? ""
        state.title = (values[1] as? String) ?? ""
        if let string = values[2] as? String {
            state.value = string
        } else if let number = values[2] as? NSNumber {
            state.value = number.stringValue
        }
        state.enabled = (values[3] as? NSNumber)?.boolValue
        state.focused = (values[4] as? NSNumber)?.boolValue
        state.selected = (values[5] as? NSNumber)?.boolValue
        return state
    }

    /// AXError → the exit code that says who has to fix it.
    static func failure(_ error: AXError, doing what: String) -> AXFailure {
        let name = axErrorName(error)
        switch error {
        case .apiDisabled:
            return .permission("accessibility was disabled while \(what): \(name)")
        case .actionUnsupported, .attributeUnsupported, .notImplemented:
            return .notActionable("\(what) is not supported by this node (\(name))")
        case .invalidUIElement, .invalidUIElementObserver:
            return .notFound("\(what) failed: the element disappeared (\(name)). A dialog that closed itself "
                + "looks like this.")
        case .cannotComplete:
            return .environment("\(what) failed: the app did not answer (\(name)). It may be busy or hung; "
                + "`krd ax doctor` shows whether the window server is answering at all.")
        default:
            return .environment("\(what) failed: \(name) (\(error.rawValue))")
        }
    }

    // MARK: - press

    static func press(_ options: AXOptions) throws -> Int32 {
        _ = try preflight(options)
        let resolved = try resolveRef(options)
        let actions = actionNames(resolved.element)
        let state = nodeState(resolved.element)
        let label = "\(options.ref ?? "node") "
            + "\(state.map { AXText.shortRole($0.role) } ?? "node")"
            + (state?.title.isEmpty == false ? " \"\(AXText.sanitize(state!.title, limit: 40))\"" : "")

        // `actionNames` returns short names ("press"), the same words `krd ax tree` prints.
        guard actions.contains(AXText.shortAction(kAXPressAction as String)) else {
            let others = actions.prefix(4)
            throw AXFailure.notActionable("\(label) does not answer press (AXPress)"
                + (others.isEmpty ? ": it has no actions at all"
                                  : "; it answers \(others.joined(separator: ", "))")
                + ". A checkbox only becomes pressable once its window is key; `krd ax tree` shows "
                + "what each node can do.")
        }
        if options.dryRun {
            print("would press \(label) (AXPress) — nothing was sent")
            print("  before: \(state?.text ?? "unknown")")
            return AXExit.ok.rawValue
        }
        let started = Date()
        let error = AXUIElementPerformAction(resolved.element, kAXPressAction as CFString)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if error != .success { throw failure(error, doing: "AXPress on \(label)") }
        let after = nodeState(resolved.element)
        print("pressed \(label) (AXPress, \(elapsed) ms)")
        print("  before: \(state?.text ?? "unknown")")
        if let after {
            print("  after : \(after.text)")
            if let state, state.text == after.text {
                print("  no observable change — some buttons only act on their target window")
            }
        } else {
            print("  after : element is gone (a dialog closed, or the view was rebuilt)")
        }
        return AXExit.ok.rawValue
    }

    // MARK: - set

    static func set(_ options: AXOptions) throws -> Int32 {
        _ = try preflight(options)
        guard let text = options.text else { throw AXFailure.usage("set needs --text <value>") }
        let resolved = try resolveRef(options)
        let state = nodeState(resolved.element)
        let label = (options.ref.flatMap { AXRef($0) }?.description ?? "node") + " "
            + (state.map { AXText.shortRole($0.role) } ?? "")
            + (state?.title.isEmpty == false ? " \"\(AXText.sanitize(state!.title, limit: 40))\"" : "")

        var settable = DarwinBoolean(false)
        let asked = AXUIElementIsAttributeSettable(resolved.element, kAXValueAttribute as CFString, &settable)
        guard asked == .success, settable.boolValue else {
            throw AXFailure.notActionable("\(label) has no settable value"
                + (asked == .success ? "" : " (\(axErrorName(asked)))")
                + ". Text fields and sliders are settable; static text and buttons are not.")
        }
        if options.dryRun {
            print("would set \(label) value \"\(AXText.sanitize(state?.value ?? "", limit: 60))\" → "
                + "\"\(AXText.sanitize(text, limit: 60))\" — nothing was sent")
            return AXExit.ok.rawValue
        }
        let started = Date()
        let error = AXUIElementSetAttributeValue(resolved.element, kAXValueAttribute as CFString, text as CFTypeRef)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if error != .success { throw failure(error, doing: "setting the value of \(label)") }

        // Read back: an app may accept the write and normalise, clamp or ignore it, and a write
        // path that reports "ok" without looking is how an agent ends up acting on a lie.
        let after = nodeState(resolved.element)
        print("set \(label) (\(elapsed) ms)")
        print("  before: \(state?.text ?? "unknown")")
        print("  after : \(after?.text ?? "element is gone")")
        guard let after else {
            throw AXFailure.notActionable("the value was accepted but the element is gone; nothing to read back")
        }
        guard after.value == text else {
            throw AXFailure.notActionable("the app accepted the write but reads back value=\""
                + "\(AXText.sanitize(after.value, limit: 60))\", not \"\(AXText.sanitize(text, limit: 60))\". "
                + "Nothing else was touched.")
        }
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
/// One emitted line, plus what it takes to find that line's element again in another process.
struct AXEntry {
    var node: AXNode
    var chain: [AXStep]
    var identifier: String
    /// Raw values, for `find`: the printed `detail` is sanitized and clipped to 60 characters.
    var rawValue: String
    var rawTitle: String
    var root: AXRoot = .window
}

struct AXWalker {
    let interactiveOnly: Bool
    let emitEverything: Bool
    /// Menu bars are walked only when asked: they are hundreds of nodes and, on a Finder
    /// desktop, reachable through a back-reference from the window tree itself.
    let includeMenus: Bool
    let maxDepth: Int
    let maxShown: Int
    let maxVisited: Int
    /// Wall-clock budget. A hung app costs up to 1.5 s per IPC and the walk makes three per
    /// node, so the node budget alone can take hours; this is the backstop that matters.
    let deadline: Date
    /// First ref number to hand out. Refs are monotonic per window (see AXIndex.counters):
    /// re-dumping a window must never make an older ref mean a different node.
    let refStart: Int
    /// Which element the chains of this walk start from. (`root` alone is the walk parameter.)
    let chainRoot: AXRoot

    var entries: [AXEntry] = []
    var nodes: [AXNode] { entries.map { $0.node } }
    var visited = 0
    var truncated = false
    /// The tree is not a tree: Finder's desktop window contains `AXApplication` children that
    /// point back at the app, whose children are the very window we started from. Measured on
    /// this machine -- without this set the walk loops and burns its whole budget on a loop.
    private var seen = Set<CFHashCode>()

    /// Explicit instead of the implicit memberwise one: `seen` is private, which makes the
    /// synthesized initializer private too, and Swift 5.10 (the macOS 14 toolchain CI uses)
    /// then rejects the call site in `tree()`. Local Swift 6.4 accepts it, so this only
    /// shows up in CI.
    init(interactiveOnly: Bool, emitEverything: Bool, includeMenus: Bool,
         maxDepth: Int, maxShown: Int, maxVisited: Int, deadline: Date, refStart: Int = 1,
         root: AXRoot = .window) {
        self.refStart = max(refStart, 1)
        self.chainRoot = root
        self.interactiveOnly = interactiveOnly
        self.emitEverything = emitEverything
        self.includeMenus = includeMenus
        self.maxDepth = maxDepth
        self.maxShown = maxShown
        self.maxVisited = maxVisited
        self.deadline = deadline
    }

    private static let attributeNames: [String] = [
        kAXRoleAttribute as String, kAXTitleAttribute as String, kAXValueAttribute as String,
        kAXIdentifierAttribute as String, kAXPositionAttribute as String, kAXSizeAttribute as String,
        kAXDescriptionAttribute as String,
    ]

    mutating func walk(root: AXUIElement, rootDepth: Int, countAsRoot: Bool) {
        // (element, depth, the chain that led here, index inside the parent's AXChildren)
        var queue: [(element: AXUIElement, depth: Int, chain: [AXStep], index: Int)] =
            [(root, rootDepth, [], -1)]
        while !queue.isEmpty {
            if Date() > deadline || visited >= maxVisited || entries.count >= maxShown {
                truncated = true
                return
            }
            let item = queue.removeFirst()
            let element = item.element
            let depth = item.depth
            guard seen.insert(CFHash(element)).inserted else { continue }
            visited += 1
            let values = AXCommand.multi(element, AXWalker.attributeNames)
            let role = (values[0] as? String) ?? ""
            var name = (values[1] as? String) ?? ""
            if name.isEmpty { name = (values[6] as? String) ?? "" }
            // Raw (unsanitized) fields for the ref chain: a ref is compared against live
            // accessibility values, never against the text this command printed.
            let rawTitle = ((values[1] as? String) ?? "").isEmpty
                ? ((values[6] as? String) ?? "") : ((values[1] as? String) ?? "")
            let identifier = (values[3] as? String) ?? ""
            let valueText = (values[2] as? String) ?? ""
            let step = AXStep(index: item.index, role: role, identifier: identifier, title: rawTitle)
            let chain = item.chain + [step]
            let origin = AXCommand.point(values[4])
            let size = AXCommand.size(values[5])
            let frame = origin.flatMap { point in size.map { CGRect(origin: point, size: $0) } }

            let cleanName = AXText.sanitize(name)
            let actions = AXCommand.actionNames(element).map(AXText.shortAction)
            // The first element of a walk is the thing the caller asked about (a window, a menu
            // bar). It earns a line even when its role is not in any list, otherwise a filter
            // can make a whole window look empty.
            let isRoot = element == root
            let isMenu = role == "AXMenuBar" || role == "AXMenu"
            // "Actionable" is checked by capability, not only by role name: Finder's desktop
            // icons are AXImage nodes that answer to open/showmenu, and a role table would
            // hide exactly the things the user wants to click.
            let shouldEmit = (isRoot || emitEverything || !actions.isEmpty
                || AXText.isEmittable(role: role, name: cleanName, interactiveOnly: interactiveOnly))
                && (!isMenu || includeMenus || isRoot)
            if shouldEmit {
                var detail = ""
                if !valueText.isEmpty {
                    detail = "value=\"\(AXText.sanitize(valueText, limit: 60))\""
                } else if !identifier.isEmpty {
                    detail = "id=\(AXText.sanitize(identifier, limit: 40))"
                }
                entries.append(AXEntry(
                    node: AXNode(
                        ref: "@e\(refStart + entries.count)",
                        depth: depth,
                        role: role,
                        name: cleanName,
                        detail: detail,
                        frame: frame,
                        actions: actions),
                    chain: chain,
                    identifier: identifier,
                    rawValue: valueText,
                    rawTitle: rawTitle,
                    root: chainRoot))
            }
            if depth >= maxDepth || (isMenu && !includeMenus) { continue }
            for (index, child) in ((AXCommand.value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).enumerated() {
                queue.append((child, depth + 1, chain, index))
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
    /// The snapshot these refs belong to (`press --snapshot`), when it could be written.
    var generation: String?

    var dictionary: [String: Any] {
        var out: [String: Any] = [
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
        if let generation { out["generation"] = generation }
        return out
    }
}
