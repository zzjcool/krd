// `krd ax …` — the headless face of krd.
//
// No frames, no terminal modes, no Screen Recording: this reads the accessibility tree
// and prints text. It runs as its own process, so an agent drives it the same way it
// drives any other CLI: one command, one result, exit code.
//
// The diagnosis is deliberately loud. Two different failures look identical from the outside
// (an empty tree and "you never granted anything"), and the difference costs users an hour, so
// the check is always made *before* either is reported -- but it is made when a verb has
// something to report, not before every verb does anything: the grant, the window list and the
// systemwide round trip cost ~50 ms of setting up two connections, and a successful `tree` pays
// none of it (issue #103). See docs/research-ax-text-channel.md §2.2 for the measurements.
//
// Where the guarantee went: every verb still exits 3 on an ungranted Mac and 4 on a Mac whose
// window server does not answer, because a verb that failed, or that read nothing, asks
// `measure()` and the answer it gets is the same sentence (and the same code) the preflight
// used to throw up front. `staged(_:…)` is the only path that decides it.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import krdcore

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
    /// `ax` is the name of the accessibility call that failed, when one did (`cannotComplete`).
    case permission(String, ax: String?)
    case environment(String, ax: String?)
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

    /// Whether a missing Accessibility grant (or a window server that stopped answering) could
    /// have produced this failure. Only failures that answer "yes" are worth the ~50 ms
    /// diagnosis: `usage` was decided before any accessibility call was made, and
    /// `notActionable` means the API answered -- the node, not the Mac, refused.
    ///
    /// `notFound` is in on purpose. "Nothing matched" is exactly what an ungranted Mac says
    /// about every query, every app and every ref, so a 5 that was really a 3 is the one
    /// mis-diagnosis that costs a user an hour (which is why the check used to run up front).
    var mayBeTheGrant: Bool {
        switch self {
        case .permission, .environment, .notFound: return true
        case .usage, .notActionable: return false
        }
    }
}

/// A failure as a machine reads it.
///
/// `--json` is a *format* switch, not a second contract: the exit code is the one text mode
/// returns, and stdout carries exactly one object in every outcome. On failure it is this one,
/// so a caller can `jq -e '.ok'` and branch on `.error.code` instead of scraping prose that was
/// written for a human (issue #123). One token per exit code, which is why `code` names the
/// class and the specific AXError the call returned rides along in `ax`.
struct AXErrorReport {
    /// `usage` | `permission` | `environment` | `notFound` | `notActionable` — one per exit code.
    var code: String
    var exit: AXExit
    /// One sentence, no `krd ax: ` stream prefix: this is a log line, not a page.
    var message: String
    /// What to do about it. Deliberately never "run `krd ax doctor`": `doctor` is one of the
    /// verbs that ends up here.
    var next: String
    /// The AXError name, when an accessibility call produced the failure.
    var ax: String?

    var dictionary: [String: Any] {
        var out: [String: Any] = ["code": code, "exit": Int(exit.rawValue),
                                  "message": message, "next": next]
        if let ax { out["ax"] = ax }
        return out
    }

    init(_ failure: AXFailure) {
        let advice: (code: String, next: String)
        let prose: String
        var ax: String?
        switch failure {
        case .usage(let message):
            advice = ("usage", "run `krd ax --help` for the commands, their arguments and the exit codes")
            prose = message
        case .permission(let message, let name):
            advice = ("permission", "grant Accessibility to this binary in System Settings > "
                + "Privacy & Security > Accessibility, then re-run")
            prose = message
            ax = name
        case .environment(let message, let name):
            advice = ("environment", "the Mac may be asleep or at the login window, or the app is "
                + "hung: wait for it to wake, then retry")
            prose = message
            ax = name
        case .notFound(let message):
            advice = ("notFound", "re-read the surface (`krd ax tree` / `krd ax find`) and use "
                + "what that dump printed")
            prose = message
        case .notActionable(let message):
            advice = ("notActionable", "re-dump and confirm the node still answers; a write the "
                + "app does not read back is not a success")
            prose = message
        }
        self.code = advice.code
        self.next = advice.next
        self.exit = failure.code
        self.ax = ax
        self.message = AXErrorReport.sentence(prose)
    }

    /// The first non-empty line, minus the stream prefix: a multi-line paragraph of advice is
    /// what stderr is for, `message` is the half a monitor logs.
    static func sentence(_ prose: String) -> String {
        let firstLine = prose.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var line = firstLine.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let prefix = "krd ax: "
        if line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
        return line
    }
}

/// Where a failed command writes, and the code it exits with.
///
/// Pure on purpose: nothing here prints or exits, so `Tests/krdTests/AXJSONFailureShapeTests.swift` can
/// pin both halves of #123 -- the shape and the exit code -- without one accessibility call.
struct AXFailureOutput {
    var stdout: String
    var stderr: String
    var code: Int32
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

/// What the three preflight answers can mean, as a value.
///
/// The preflight used to ask its three questions before every verb and turn "no" into an exit
/// code inline (issue #103). The questions still get asked -- of a verb that failed, or read
/// nothing -- and this is where their answers become a decision, so the mapping is a unit test
/// (`AXPreflightVerdictTests`) instead of something a grant-less machine cannot exercise.
///
/// The cases are the two codes `krd ax doctor` exits on a red diagnosis (3, 4) plus the green
/// one: there is no fourth answer, and adding one here without a code in `usage()` would be a
/// contract change, not a refinement.
enum AXReadiness: Equatable {
    /// Granted, and the accessibility API answers: nothing to say about this Mac.
    case ready
    /// No grant for this binary → exit 3, `permissionText`.
    case untrusted
    /// Granted, but the window server does not answer → exit 4, `environmentText`.
    case notAnswering

    /// The whole decision, in one place. `answers` is what the systemwide round trip said
    /// (`success`, `noValue` and `attributeUnsupported` all mean "the API is alive").
    static func of(trusted: Bool, answers: Bool) -> AXReadiness {
        if answers { return .ready }
        return trusted ? .notAnswering : .untrusted
    }
}

/// What `krd ax doctor` measured, split from the accessibility calls that measured it, so the
/// reporting and the exit code are pure and testable (issue #123).
struct AXDiagnosis {
    var trusted: Bool
    var onScreenWindows: Int
    var answers: Bool
    var first: AXError
    var final: AXError
    /// Whether the 120 ms retry happened (`cannotComplete` on the first call is startup noise).
    var retried: Bool
    var sample: String

    /// The verdict the preflight used to throw on, read off the measurement.
    var readiness: AXReadiness { AXReadiness.of(trusted: trusted, answers: answers) }

    /// A red diagnosis is not a successful run, and `--json` does not change that: 3 when the
    /// grant is missing, 4 when the accessibility API does not answer.
    var exit: AXExit {
        switch readiness {
        case .ready: return .ok
        case .untrusted: return .permission
        case .notAnswering: return .environment
        }
    }

    /// The failure a red diagnosis reports -- the same sentences text mode prints, so the two
    /// surfaces cannot drift apart, and nil on a green Mac.
    var failure: AXFailure? {
        // The AXError that measured red rides along in `ax` in both branches, so a caller loses
        // nothing by reading `.error.ax` instead of the string the old `error` field held.
        switch readiness {
        case .ready:
            return nil
        case .untrusted:
            return .permission(AXCommand.permissionText, ax: AXCommand.axErrorName(final))
        case .notAnswering:
            return .environment(AXCommand.environmentText(error: final),
                                ax: AXCommand.axErrorName(final))
        }
    }
}

/// The two renderings of a diagnosis, plus the code it earns.
struct AXDoctorOutput {
    var text: String
    /// The same advice `text` ends with, for `--json`: stdout carries one object, so the prose a
    /// human needs (the grant walkthrough, or the "the Mac may be asleep" paragraph) goes here.
    var stderr: String
    var json: [String: Any]
    var exit: AXExit
}

enum AXCommand {
    static func isInvocation(_ args: [String]) -> Bool {
        args.first == "ax"
    }

    /// Entry point. Never returns: every path ends in exit(), so the render loop and its
    /// NSApplication context are never started.
    static func run(_ args: [String]) -> Never {
        // Read from the raw argv first: an unknown flag or a missing verb fails *while parsing*,
        // before the parser could have seen `--json`, and it still has to answer in the format
        // the caller asked for. Once the parser has run, its answer wins -- a `--json` that was
        // really the value of `--app` is not the flag.
        var requestedJSON = wantsJSON(args)
        if args.contains("-h") || args.contains("--help") || args.first == "help" {
            print(usage())
            exit(AXExit.ok.rawValue)
        }
        do {
            let options = try parse(args)
            requestedJSON = options.json
            // Every verb but `doctor` runs through `staged`: it is the one place that decides,
            // after the fact, whether a failure was the Mac's fault (exit 3 / 4) or the verb's.
            switch options.verb {
            case "windows": exit(try staged(options, retrying: false) { try windows(options) })
            case "tree": exit(try staged(options) { try tree(options) })
            case "screen": exit(try staged(options) { try screen(options) })
            case "doctor": exit(try doctor(options))
            case "find": exit(try staged(options) { try find(options) })
            // Writes are never retried: an `AXPress` that returned `cannotComplete` may have
            // landed, and a retry would be a second click on whatever is there now.
            case "press": exit(try staged(options, retrying: false) { try press(options) })
            case "set": exit(try staged(options, retrying: false) { try set(options) })
            default:
                throw AXFailure.usage("unknown command \"\(options.verb)\" (try `krd ax --help`)")
            }
        } catch let failure as AXFailure {
            exit(fail(failure, json: requestedJSON))
        } catch {
            // Not an AXFailure (a failed allocation, a thrown string): still a failure the
            // machine has to see, and still the environment's fault until proven otherwise.
            exit(fail(.environment("krd ax: \(error)", ax: nil), json: requestedJSON))
        }
    }

    /// Whether the caller asked for machine output. Read from the raw argv, never from the
    /// parsed options: a usage failure happens mid-parse, which is exactly the moment the parser
    /// cannot yet tell you `--json` was asked for (#123).
    static func wantsJSON(_ args: [String]) -> Bool { args.contains("--json") }

    /// Every successful `--json` answer says so, in one place: a caller can `jq -e '.ok'` on any
    /// verb instead of knowing which ones answer with `{"windows":…}` and which with `[…]`.
    static func success(_ payload: [String: Any]) -> [String: Any] {
        var out = payload
        out["ok"] = true
        return out
    }

    /// The one place a failed command becomes output: the prose a human reads (unchanged since
    /// before #123) on stderr, and when `--json` was asked for, exactly one object on stdout.
    static func failureOutput(_ failure: AXFailure, json: Bool) -> AXFailureOutput {
        var out = AXFailureOutput(stdout: "", stderr: describe(failure) + "\n",
                                  code: failure.code.rawValue)
        // A usage failure adds the whole surface to stderr: the reader asked for the wrong thing
        // and needs the list. (`--json` callers get the same in `next`.)
        if case .usage(let message) = failure { out.stderr = message + "\n\n" + usage() }
        if json {
            out.stdout = jsonString(["ok": false, "error": AXErrorReport(failure).dictionary]) + "\n"
        }
        return out
    }

    /// Write `failureOutput(_:json:)` out and answer with the code to exit on.
    static func fail(_ failure: AXFailure, json: Bool) -> Int32 {
        let output = failureOutput(failure, json: json)
        if !output.stdout.isEmpty { FileHandle.standardOutput.write(Data(output.stdout.utf8)) }
        FileHandle.standardError.write(Data(output.stderr.utf8))
        return output.code
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

        exit  0  ok — and a green krd ax doctor
              2  usage: unknown flag or verb, or a missing/malformed value
              3  no Accessibility permission
              4  the accessibility API is not answering: the Mac asleep or locked, the window
                 server gone, every app that could answer hung
              5  nothing matched: a query, app or ref found nothing (an empty krd ax windows list exits 0)
              6  the node refused the action, or the app read back something else

        krd ax doctor exits 3 or 4 on a red diagnosis instead of 0, in text and --json alike, so
        krd ax doctor && krd ax windows is a health check that cannot pass on a broken Mac.
        The same six are in README.md and docs/TROUBLESHOOTING.md §6, word for word.

        --json is a format switch, not a second contract: the exit code above is the same one in
        both formats, stdout carries exactly one JSON object for every command outcome (a
        `--help` request still answers in text), and the prose stays on stderr. `next` never
        says "run `krd ax doctor`": doctor is itself one of the verbs whose failure ends up
        here. A failed command prints

          {"ok": false, "error": {"code": "environment", "exit": 4,
                                   "message": "the accessibility API is not answering (cannotComplete)",
                                   "next": "the Mac may be asleep or at the login window…",
                                   "ax": "cannotComplete"}}

        where code is usage|permission|environment|notFound|notActionable (one per exit code),
        exit is that same number, and ax is the AXError name for the permission and environment
        classes; the node-level codes (5, 6) name theirs inside message, next to the node they
        were read from. A consumer that used to match on the name alone (the "error" field of the
        old doctor payload) reads error.ax now. A successful command carries "ok": true and its
        usual fields; `press`/`set` answer
        {"ok": true, "command": "press|set", "ref": "@e7", "label": "…", "before": "…",
         "after": "…", "elapsedMs": 3} — `press` answers after: null and a "note" when the
        element went away (a `set` in that state fails with 6, "nothing to read back"), `set`
        also echoes the "value" it wrote, `press` adds the same "note" when the write landed but
        read back unchanged, and `--dry-run` answers that same shape with "dryRun": true and no
        after/elapsedMs, because nothing was sent. On a red diagnosis `doctor` reports its measured fields
        alongside {"ok": false, "error": {…}}; on a green Mac its `error` is still the AXError
        name it has always been, and ok is true.

        Reads are the default and need no flags; press/set are explicit subcommands, and every
        write prints the state it read back afterwards. This command never captures a frame, so
        it needs Accessibility but not Screen Recording. See docs/research-ax-text-channel.md.
        """
    }

    // MARK: - the diagnosis, on demand

    /// The process-wide messaging timeout, and nothing else.
    ///
    /// The preflight set this up because it was already holding a systemwide element; skipping
    /// the preflight must not skip *this*, because the default ~6 s per IPC turns one hung app
    /// into a hung CLI and every element the walk creates inherits the setting. It costs no round
    /// trip: `AXUIElementCreateSystemWide` hands back a local proxy and the timeout is stored on
    /// the process, not read from the window server (Apple's own contract: setting it on the
    /// system-wide element is the only way to bound every element, and is why it is here).
    static func configure() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
    }

    /// Every question the preflight asked, measured once, in the order it asked them.
    ///
    /// This is the ~50 ms the issue measured (8 ms trust + 22–28 ms window list + 17.5–20.5 ms
    /// first round trip) and the reason it is no longer on the success path: two of the three
    /// results exist only to spell a failure message. `doctor` reports the measurement; a failed
    /// or empty verb reads `.readiness` off it and throws if the Mac is the reason.
    ///
    /// The warm-up stays: a process in an ssh (Background) session gets `cannotComplete` on its
    /// first accessibility call and succeeds on a retry made after it has touched the window
    /// server, so the window list is read first and the round trip is retried once after 120 ms.
    /// A diagnosis that survives the retry is a real problem, not startup noise.
    static func measure() -> AXDiagnosis {
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

        return AXDiagnosis(trusted: trusted, onScreenWindows: onScreen, answers: answers,
                           first: first, final: final, retried: second != nil, sample: sample)
    }

    /// The preflight's question, asked at the one moment the answer changes anything: a verb that
    /// has a failure in hand. Throws the canonical 3 / 4 failure when the Mac is the reason, and
    /// returns the measurement when it is not (so "nothing matched" keeps its own code).
    @discardableResult
    static func requireReady() throws -> AXDiagnosis {
        configure()
        let diagnosis = measure()
        if let failure = diagnosis.failure { throw failure }
        return diagnosis
    }

    /// Run one verb with the guarantee the preflight gave, without paying for it when nothing is
    /// wrong.
    ///
    /// A successful answer is returned untouched and costs no diagnosis. A failure is diagnosed
    /// only when a missing grant could have produced it (`usage` was decided before any
    /// accessibility call, and `notActionable` means the API answered), because the alternative
    /// is the hour-long confusion the loud preflight existed to prevent: an ungranted Mac saying
    /// "nothing matched" about everything, at exit 5.
    ///
    /// A *green* diagnosis plus an environment failure is startup noise, so the body is run a
    /// second time -- `measure()` has just touched the window server, which is exactly the retry
    /// the preflight used to make up front. Reads only: an `AXPress` that returned
    /// `cannotComplete` may have landed, and a second one would be a second click.
    static func staged(_ options: AXOptions, retrying: Bool = true,
                       diagnose: () -> AXDiagnosis = measure,
                       _ body: () throws -> Int32) throws -> Int32 {
        if options.prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        configure()
        do {
            return try body()
        } catch let failure as AXFailure where failure.mayBeTheGrant {
            configure()
            if let reason = diagnose().failure { throw reason }
            // Green: the Mac is fine, so the failure came from this process's own first call.
            if retrying, case .environment = failure { return try body() }
            throw failure
        }
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
        case .permission(let message, _): return message
        case .environment(let message, _): return message
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
        // commands cannot run at all. It is also the one verb that pays for the whole
        // measurement on the success path -- `onScreenWindows` is a field it prints and
        // nothing else ever read (issue #103).
        let report = doctorOutput(measure())
        if options.json {
            // Same writer as `fail()`, and stdout first: when a caller merges the two streams
            // (`2>&1`) the object must still be the first thing on the line it starts.
            FileHandle.standardOutput.write(Data((jsonString(report.json) + "\n").utf8))
            if !report.stderr.isEmpty { FileHandle.standardError.write(Data(report.stderr.utf8)) }
        } else {
            print(report.text)
        }
        // The same code in both formats (#123): a health check that asks for parseable output
        // must not be told the Mac is fine when it is not.
        return report.exit.rawValue
    }

    /// Both renderings of a diagnosis, and the code it earns. Pure, so "a failing diagnosis must
    /// not exit 0" is a unit test instead of a manual run on a broken Mac.
    static func doctorOutput(_ diagnosis: AXDiagnosis) -> AXDoctorOutput {
        var text = [
            "accessibility permission  \(diagnosis.trusted ? "granted" : "MISSING")",
            "accessibility answers     \(diagnosis.answers ? "yes" : "no (\(axErrorName(diagnosis.final)))")",
            "window server             "
                + (diagnosis.onScreenWindows >= 0
                    ? "\(diagnosis.onScreenWindows) windows on screen" : "unreachable"),
            "first call in this process \(axErrorName(diagnosis.first))"
                + (diagnosis.retried ? " → retry \(axErrorName(diagnosis.final))" : ""),
            "frontmost app             \(diagnosis.sample)",
        ].joined(separator: "\n")
        if let failure = diagnosis.failure { text += "\n\n" + describe(failure) }

        var json: [String: Any] = [
            "ok": diagnosis.answers,
            "trusted": diagnosis.trusted,
            "answers": diagnosis.answers,
            "onScreenWindows": diagnosis.onScreenWindows,
            "firstCall": axErrorName(diagnosis.first),
            "sample": diagnosis.sample,
        ]
        // `error` holds the AXError name on a green Mac, exactly as it did before #123. On a red
        // one it becomes the failure object every `--json` verb uses, and the AXError name it
        // used to hold is at `error.ax` (and in `firstCall`), so nothing is lost.
        if let failure = diagnosis.failure {
            json["error"] = AXErrorReport(failure).dictionary
        } else {
            json["error"] = axErrorName(diagnosis.final)
        }
        return AXDoctorOutput(text: text,
                              stderr: diagnosis.failure.map { describe($0) + "\n" } ?? "",
                              json: json, exit: diagnosis.exit)
    }

    static func windows(_ options: AXOptions) throws -> Int32 {
        // One window list, once: the preflight read one and threw it away, and `onScreenApps`
        // read another (issue #103).
        let list = onScreenApps(windows: windowList())
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
            // An empty list is the answer only if the Mac is answering: `--json` must not report
            // zero windows on a Mac that never granted the read (exit 3), nor one whose window
            // server is gone (exit 4). Same question the preflight asked, asked only here.
            if rows.isEmpty { try requireReady() }
            print(jsonString(success(["windows": rows.map { $0.dictionary }])))
            return AXExit.ok.rawValue
        }
        if rows.isEmpty {
            try requireReady()
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
        let apps = onScreenApps(windows: windowList())
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
        // Zero apps with a readable window is either the truth (a Mac with nothing on screen) or
        // a read that never happened -- the same two failures the preflight separated, separated
        // here because this is where the two are indistinguishable.
        if jsonApps.isEmpty { try requireReady() }
        if options.json {
            print(jsonString(success(["apps": jsonApps, "focus": focus])))
        } else {
            print(out.joined(separator: "\n"))
        }
        return AXExit.ok.rawValue
    }

    static func tree(_ options: AXOptions) throws -> Int32 {
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

        let dump = AXRefStore().beginDump(bundle: app.bundle, window: options.windowIndex)
        var reader = AXWalker(
            interactiveOnly: options.interactiveOnly && !options.all,
            emitEverything: options.all,
            includeMenus: options.menuBar,
            maxDepth: options.depth,
            maxShown: options.maxNodes,
            maxVisited: max(options.maxNodes * 8, 2000),
            deadline: Date().addingTimeInterval(10),
            refStart: dump.refStart)
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
                                 count: windows.count, entries: reader.entries, dump: dump)
        if options.json {
            print(jsonString(success(AXTreeJSON(
                app: app.name, pid: app.pid, windowIndex: options.windowIndex,
                windowCount: windows.count, windowTitle: title,
                frame: frame(window), nodes: reader.nodes,
                truncated: reader.truncated, visited: reader.visited,
                generation: generation).dictionary)))
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
                        entries: [AXEntry], dump: AXRefStore.Dump) -> String? {
        guard !entries.isEmpty else { return nil }
        let snapshot = AXSnapshot(
            schema: AXSnapshot.schema,
            generation: UUID().uuidString,
            createdAt: Date(),
            app: app.name, bundle: app.bundle, pid: app.pid,
            windowIndex: index, windowTitle: window, windowCount: count,
            nodes: entries.map { AXSnapshotNode(ref: $0.node.ref, chain: $0.chain, root: $0.root) })
        do {
            try dump.save(snapshot)
            return snapshot.generation
        } catch {
            FileHandle.standardError.write(Data(
                "krd ax: could not save refs (\(error)); `press`/`set` will not resolve them\n".utf8))
            return nil
        }
    }

    // MARK: - find

    static func find(_ options: AXOptions) throws -> Int32 {
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
        let dump = AXRefStore().beginDump(bundle: app.bundle, window: options.windowIndex)
        var reader = AXWalker(
            interactiveOnly: false,
            emitEverything: options.all,
            includeMenus: options.menuBar,
            maxDepth: options.depth,
            maxShown: options.maxNodes,
            maxVisited: max(options.maxNodes * 8, 2000),
            deadline: Date().addingTimeInterval(10),
            refStart: dump.refStart)
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
                                 count: windows.count, entries: reader.entries, dump: dump)
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
            print(jsonString(success(payload)))
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
                    + "the app is not answering. Try again, or re-dump with -d to shorten the chain.",
                    ax: nil)
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
            return .permission("accessibility was disabled while \(what): \(name)", ax: name)
        case .actionUnsupported, .attributeUnsupported, .notImplemented:
            return .notActionable("\(what) is not supported by this node (\(name))")
        case .invalidUIElement, .invalidUIElementObserver:
            return .notFound("\(what) failed: the element disappeared (\(name)). A dialog that closed itself "
                + "looks like this.")
        case .cannotComplete:
            return .environment("\(what) failed: the app did not answer (\(name)). It may be busy or hung; "
                + "`krd ax doctor` shows whether the window server is answering at all.", ax: name)
        default:
            return .environment("\(what) failed: \(name) (\(error.rawValue))", ax: name)
        }
    }

    // MARK: - press

    static func press(_ options: AXOptions) throws -> Int32 {
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
            if options.json {
                print(jsonString(pressResult(ref: options.ref ?? "", label: label, dryRun: true,
                                            elapsedMs: 0, before: state?.text ?? "unknown",
                                            after: nil, note: nil)))
            } else {
                print("would press \(label) (AXPress) — nothing was sent")
                print("  before: \(state?.text ?? "unknown")")
            }
            return AXExit.ok.rawValue
        }
        let started = Date()
        let error = AXUIElementPerformAction(resolved.element, kAXPressAction as CFString)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if error != .success { throw failure(error, doing: "AXPress on \(label)") }
        let after = nodeState(resolved.element)
        if options.json {
            // The write landed. Everything the text lines say is here as a field, and the
            // caller gets `ok:true` instead of having to recognise the sentence.
            print(jsonString(pressResult(
                ref: options.ref ?? "", label: label, dryRun: false, elapsedMs: elapsed,
                before: state?.text ?? "unknown", after: after?.text,
                note: after == nil ? "element is gone (a dialog closed, or the view was rebuilt)"
                    : (state.map { $0.text == after!.text } == true
                        ? "no observable change — some buttons only act on their target window" : nil))))
            return AXExit.ok.rawValue
        }
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
            if options.json {
                print(jsonString(setResult(ref: options.ref ?? "", label: label, value: text,
                                           dryRun: true, elapsedMs: 0,
                                           before: state?.text ?? "unknown", after: nil)))
            } else {
                print("would set \(label) value \"\(AXText.sanitize(state?.value ?? "", limit: 60))\" → "
                    + "\"\(AXText.sanitize(text, limit: 60))\" — nothing was sent")
            }
            return AXExit.ok.rawValue
        }
        let started = Date()
        let error = AXUIElementSetAttributeValue(resolved.element, kAXValueAttribute as CFString, text as CFTypeRef)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if error != .success { throw failure(error, doing: "setting the value of \(label)") }

        // Read back: an app may accept the write and normalise, clamp or ignore it, and a write
        // path that reports "ok" without looking is how an agent ends up acting on a lie.
        let after = nodeState(resolved.element)
        // In text mode the before/after pair is printed before the read-back is judged, so a
        // failed write still shows the reader what the field holds now. In JSON mode nothing but
        // the answer may reach stdout, so that pair is built last, once the guards have passed.
        if !options.json {
            print("set \(label) (\(elapsed) ms)")
            print("  before: \(state?.text ?? "unknown")")
            print("  after : \(after?.text ?? "element is gone")")
        }
        guard let after else {
            throw AXFailure.notActionable("the value was accepted but the element is gone; nothing to read back")
        }
        guard after.value == text else {
            throw AXFailure.notActionable("the app accepted the write but reads back value=\""
                + "\(AXText.sanitize(after.value, limit: 60))\", not \"\(AXText.sanitize(text, limit: 60))\". "
                + "Nothing else was touched.")
        }
        if options.json {
            print(jsonString(setResult(ref: options.ref ?? "", label: label, value: text,
                                       dryRun: false, elapsedMs: elapsed,
                                       before: state?.text ?? "unknown", after: after.text)))
        }
        return AXExit.ok.rawValue
    }

    // MARK: - the machine answer to a write

    /// `press --json`. Pure, so the payload can be asserted without a grant or a running app, and
    /// so `press` cannot drift from the shape `set` and the failure path use (#123).
    static func pressResult(ref: String, label: String, dryRun: Bool, elapsedMs: Int,
                            before: String, after: String?, note: String?) -> [String: Any] {
        var out: [String: Any] = ["ok": true, "command": "press", "ref": ref, "label": label,
                                  "before": before]
        if dryRun {
            out["dryRun"] = true
        } else {
            out["elapsedMs"] = elapsedMs
            out["after"] = after ?? NSNull()
        }
        if let note { out["note"] = note }
        return out
    }

    /// `set --json`: the value that was written, and the state read back on both sides of it.
    static func setResult(ref: String, label: String, value: String, dryRun: Bool, elapsedMs: Int,
                          before: String, after: String?) -> [String: Any] {
        var out: [String: Any] = ["ok": true, "command": "set", "ref": ref, "label": label,
                                  "value": value, "before": before]
        if dryRun {
            out["dryRun"] = true
        } else {
            out["elapsedMs"] = elapsedMs
            out["after"] = after ?? NSNull()
        }
        return out
    }

    // MARK: - app resolution

    struct RunningApp {
        var pid: pid_t
        var name: String
        var bundle: String
        var active: Bool
    }

    static func onScreenApps(windows: [[String: Any]]) -> [RunningApp] {
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

    /// The one `CGWindowListCopyWindowInfo` a verb needs, in the shape `onScreenApps` reads.
    ///
    /// First call in a process is 22–28 ms and the second identical one is 0.7–1 ms (issue #103),
    /// so it is measured work, not enumeration: `windows` and `screen` used to pay for two of
    /// them (preflight + `onScreenApps`) and now pay for one.
    static func windowList() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                    kCGNullWindowID) as? [[String: Any]]) ?? []
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

/// Breadth-first, budgeted, and attribute-batched: **two** IPC per node
/// (`CopyMultipleAttributeValues` — children included — plus action names) instead of nine.
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

/// The accessibility reads a walk is built out of, behind one seam.
///
/// Why a seam: a walk's cost *is* its round trips, and a round trip can be neither counted nor
/// timed from a process that holds no Accessibility grant (this machine answers `err=-25208` and
/// every slot is nil). With the reads injectable, `AXWalkRoundTripTests` runs a synthetic tree
/// through the real `walk` and asserts the calls per node and the tree that comes out — which is
/// the only way the "3 → 2" of issue #104 can be stated as a number rather than a claim.
///
/// Production is `.system`: these three calls, in this order, and nothing else. They are
/// `AXCommand`'s own helpers so the failure handling (`multi` tolerating holes, `actionNames`
/// dropping private actions, `value` swallowing a bad app) does not fork.
struct AXAccess {
    /// `AXUIElementCopyMultipleAttributeValues`, normalized to one slot per requested name.
    var batch: (AXUIElement, [String]) -> [AnyObject?]
    /// `AXUIElementCopyActionNames`, filtered to standard actions and short names.
    var actions: (AXUIElement) -> [String]
    /// `AXUIElementCopyAttributeValue`. The walk itself only needs it for the children fallback
    /// below; the reads around the walk (`windows`, `frame`, the ref chain) still use it.
    var value: (AXUIElement, String) -> AnyObject?
    /// Whether `batch` carries `AXChildren` in its last slot.
    ///
    /// Real AX does (#104: `err=0, n=8`, children as the 8th value; an unsupported name in the
    /// same batch does not fail it). `false` is the pre-#104 shape — children from a read of
    /// their own — and exists so `AXWalkRoundTripTests` can run both shapes over one tree and
    /// require one output from them; nothing in the production path sets it to `false`.
    var carriesChildren: Bool = true

    static let system = AXAccess(batch: AXCommand.multi, actions: AXCommand.actionNames,
                                 value: AXCommand.value)

    /// The children of `element`, reusing `values` when they rode in the batch.
    ///
    /// A hole in the children slot is **not** read as "leaf": it takes the separate read. Two
    /// reasons. A leaf answers with an *empty* array, not with nothing — the issue's own locked
    /// session reports `AXChildren == 0` for every window, i.e. an answer of zero elements — so a
    /// hole means the element did not answer the attribute, and "does not answer" must not be
    /// spelled the same way as "has nothing under it": that is the one way this change could lose
    /// a subtree silently, and reporting a broken subtree as empty is the worst answer a tool
    /// whose product is "what is on screen" can give. And a hole is exactly the node the
    /// pre-#104 walk paid a read for, so this can only ever cost what the walk already cost.
    ///
    /// The all-nil batch (an app that does not implement multi-value reads, or a grant that
    /// lapsed mid-walk) lands here too, which is what keeps such a subtree walkable.
    func children(of element: AXUIElement, from values: [AnyObject?]) -> [AXUIElement] {
        if carriesChildren, let inBatch = AXAccess.elements(values.last ?? nil) { return inBatch }
        return AXAccess.elements(value(element, kAXChildrenAttribute)) ?? []
    }

    /// The `AXUIElement`s in `raw`, or `nil` when it is not a list of elements.
    ///
    /// Two casts on purpose: the batch hands back the raw `CFArray` (`AnyObject`), and a value
    /// that only bridges as `[AnyObject]` should still be read as children rather than costing a
    /// redundant read. The per-element test is `AXCommand.asElement`'s, the same one the ref
    /// chain already trusts.
    static func elements(_ raw: AnyObject?) -> [AXUIElement]? {
        guard let raw else { return nil }
        if let typed = raw as? [AXUIElement] { return typed }
        guard let list = raw as? [AnyObject] else { return nil }
        let elements = list.compactMap { AXCommand.asElement($0) }
        return elements.count == list.count ? elements : nil
    }
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
    /// Wall-clock budget. A hung app costs up to 1.5 s per IPC and the walk makes two per
    /// node, so the node budget alone can take hours; this is the backstop that matters.
    let deadline: Date
    /// First ref number to hand out. Refs are monotonic per window (see AXIndex.counters):
    /// re-dumping a window must never make an older ref mean a different node.
    let refStart: Int
    /// Which element the chains of this walk start from. (`root` alone is the walk parameter.)
    let chainRoot: AXRoot
    /// The accessibility reads this walk is allowed to make. `.system` in production; the
    /// synthetic tree in `AXWalkRoundTripTests` counts them instead of paying for them (#104).
    let access: AXAccess

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
         root: AXRoot = .window, access: AXAccess = .system) {
        self.access = access
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

    /// Everything one node is read for, in one `CopyMultipleAttributeValues`. The order is the
    /// slot order `walk` indexes into, so `children` stays last.
    ///
    /// `AXChildren` is here because it is an ordinary attribute and a batch is one round trip
    /// whatever it carries — which is the claim this change makes, and the only one it needs.
    /// The issue measures that batch twice on an M4 Pro/macOS 27: `batch(7 attrs)` = 0.059 ms and
    /// `batch(7 + children)` = 0.265 ms in the constants table, 0.305 ms in the summary — i.e. the
    /// children array costs 0.2–0.25 ms *of marshalling, not of a round trip*, and the batch still
    /// answers `err=0, n=8`. So the wall clock per node is a wash-to-slightly-worse in the worst
    /// reading (0.310 → 0.325 ms) and the round trips — what dominates on the documented apps and
    /// what survives a slow app — are a third fewer. An unsupported *name* in the same batch does
    /// not fail it either (it comes back as a hole), so this cannot cost a round trip (issue #104).
    static let attributeNames: [String] = [
        kAXRoleAttribute as String, kAXTitleAttribute as String, kAXValueAttribute as String,
        kAXIdentifierAttribute as String, kAXPositionAttribute as String, kAXSizeAttribute as String,
        kAXDescriptionAttribute as String, kAXChildrenAttribute as String,
    ]

    /// The same read for a node whose children will be thrown away (`--max` depth reached): the
    /// array is the 0.2–0.25 ms above, so a node at the limit must not pay to marshal it. Before
    /// #104 such a node paid nothing for children either; it still pays exactly two round trips.
    ///
    /// Only the depth prune is covered here — a menu node pruned by `--no-menubar` still carries
    /// the children array in its batch, because `role` is not known before the read. The cost is
    /// bounded by the menu bar itself, which is walked only when asked for.
    static let attributeNamesAtLimit: [String] = Array(attributeNames.dropLast())

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
            // Known before the read, unlike `role`: a node at the depth limit has its children
            // discarded, so it must not ask for them.
            let atLimit = depth >= maxDepth
            let values = access.batch(element, atLimit ? AXWalker.attributeNamesAtLimit
                                                       : AXWalker.attributeNames)
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
            let actions = access.actions(element).map(AXText.shortAction)
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
            if atLimit || (isMenu && !includeMenus) { continue }
            for (index, child) in access.children(of: element, from: values).enumerated() {
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
