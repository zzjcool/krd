import Foundation
import CoreGraphics
import ApplicationServices

// Shared plumbing for both halves of the driver: the exit codes, the option parser, and the
// trust check that decides whether anything we post will be seen at all.

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

/// exit: 0 posted / written · 2 usage · 3 the system refused (no Accessibility / Screen Recording)
let EXIT_USAGE: Int32 = 2
let EXIT_REFUSED: Int32 = 3
let EXIT_ENVIRONMENT: Int32 = 4

/// A verb's arguments split into positional values and `--name value` options, parsed once so a
/// flag can appear anywhere without every verb needing its own parser.
struct Args {
    var verb: String = ""
    var positional: [String] = []
    var opts: [String: String] = [:]

    init(_ raw: [String]) {
        var rest = raw
        if let first = rest.first, !first.hasPrefix("--") {
            verb = first
            rest.removeFirst()
        }
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                    opts[name] = rest[i + 1]
                    i += 2
                } else {
                    opts[name] = "true"
                    i += 1
                }
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func opt(_ name: String, _ fallback: String? = nil) -> String? { opts[name] ?? fallback }
    func int(_ name: String, _ fallback: Int) -> Int { Int(opts[name] ?? "") ?? fallback }
    func double(_ name: String, _ fallback: Double) -> Double { Double(opts[name] ?? "") ?? fallback }

    func point(_ index: Int, _ verbName: String) -> CGPoint {
        guard positional.count > index + 1,
              let x = Double(positional[index]), let y = Double(positional[index + 1]) else {
            fail(EXIT_USAGE, "\(verbName) needs absolute coordinates, e.g. `\(verbName) 812 340`")
        }
        return CGPoint(x: x, y: y)
    }
}

/// macOS hands Accessibility to a *binary identity*, not to a shell, so a helper built by an agent
/// is either trusted or it is not — and "not" must be loud. Posting events while untrusted is
/// silent by design (that is the TCC model), which would turn every failed test into a mystery.
func requireEventAccess() {
    if !AXIsProcessTrusted() || !CGPreflightPostEventAccess() {
        fail(EXIT_REFUSED, "not trusted to post events: grant Accessibility to this binary "
            + "(run `kagent doctor --fix` on the target)")
    }
}
