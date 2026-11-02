import Foundation
import CoreGraphics
import ScreenCaptureKit

/// Why a panel has no picture. The wall draws a mask for every one of these (design §6.6): a card
/// must never show a stale picture of a window that is gone, and a denied capture is not an error
/// the reader can act on mid-screen.
extension PanelCaptureError {
    /// The reason in the words a mask has room for - one short word, because it is drawn *inside* a
    /// card that may be 20 cells wide. "no picture" is the same rectangle for every cause, so this is
    /// the only place a reader can learn why: `closed` (the window went away), `denied` (Screen
    /// Recording), `no stream` (the window server refuses this window - `-3805`), `no pixels` (the
    /// stream produced nothing), `failed` (anything else).
    var maskLabel: String {
        switch self {
        case .windowGone: return "closed"
        case .denied: return "denied"
        case .noPixelBuffer: return "no pixels"
        case let .failed(message):
            // `-3805` is "failed during stream": ScreenCaptureKit hands back a display and refuses a
            // window (a VM's window server does it for every window), which is not a permission
            // problem and not something a repaint can fix.
            return message.contains("3805") ? "no stream" : "failed"
        }
    }
}

enum PanelCaptureError: Error, Equatable {
    case windowGone        // the window id no longer resolves (closed, or minimised away)
    case denied            // Screen Recording refused (SCStreamErrorUserDeclined / missing entitlement)
    case noPixelBuffer     // the stream produced nothing usable
    case failed(String)    // anything else, message only
}

/// Who macOS asks for the Screen Recording grant when a capture is refused (issue #219).
///
/// TCC does not ask the process that calls ScreenCaptureKit. It asks that process's **responsible
/// process** — the app the user started, or the login session it runs in — and a child inherits it,
/// so one grant covers everything a session runs. Two measurements from this tree:
///
///  * a shell inside a terminal app: the grant is the *terminal app's*. The TCC log line for an
///    access request krd itself made reads `from Sub:{com.superlogical.rex.server}`
///    `Resp:{… responsible_path=…/Rex Server.app/Contents/MacOS/rex}`, and a freshly built,
///    never-granted ad-hoc binary captures from that shell — the answer was Rex's, not krd's.
///  * an SSH login session: `sshd` runs it under `/usr/libexec/sshd-keygen-wrapper`, which is the
///    path that answers. Measured on the tart VM: its TCC database grants `kTCCServiceScreenCapture`
///    to that path and has **no** krd row at all, and a never-granted binary copied there captures
///    over SSH.
///
/// So the binary's own identifier and signature decide nothing here — which is also why
/// `tccutil reset ScreenCapture com.kkrt.macdesk` answers `-10814 No such bundle identifier`: that
/// command resolves *bundle* identifiers through LaunchServices, and a bare executable's identifier
/// is not one of them. What the sentences below name is the process a reader has to grant.
enum CaptureAuthority: Equatable {
    /// The GUI terminal app a shell runs under (`TERM_PROGRAM`).
    case terminalApp(String)
    /// The process an SSH login session runs under: `sshd`'s session wrapper.
    case sshLoginSession
    /// Neither fact is available (no SSH, no `TERM_PROGRAM`): the sentences stay generic.
    case unknown

    /// What System Settings lists when an SSH session is the thing being granted. `sshd` runs every
    /// login session under this path, so granting it covers `ssh host krd` and everything else that
    /// session starts — including a binary that was never granted and never will be.
    static let sshLoginProcess = "/usr/libexec/sshd-keygen-wrapper"

    /// Which session this process is in, from the two facts a session puts in its environment.
    ///
    /// SSH first: an SSH session's shell is not a child of the terminal app on the reader's desk, so
    /// `TERM_PROGRAM` — which the client forwards, and which names the *client's* terminal — is not
    /// the process that answers for it. `SSH_CONNECTION`/`SSH_TTY` are what `sshd` sets in every
    /// login session.
    static func current(_ environment: [String: String]) -> CaptureAuthority {
        if environment["SSH_CONNECTION"] != nil || environment["SSH_TTY"] != nil {
            return .sshLoginSession
        }
        if let program = environment["TERM_PROGRAM"], !program.isEmpty {
            return .terminalApp(program)
        }
        return .unknown
    }

    /// `Apple_Terminal` is the identifier; the row in System Settings says `Terminal`, so that one
    /// is spelled out. (`WallNotice` maps the same pair, for a caller that hands it a verbatim
    /// `TERM_PROGRAM`.)
    private static func shown(_ program: String) -> String {
        program == "Apple_Terminal" ? "Terminal" : program
    }

    /// The name to grant, or `nil` when krd cannot tell who that is (a footer then says "your
    /// terminal").
    var grantTarget: String? {
        switch self {
        case let .terminalApp(program): return Self.shown(program)
        case .sshLoginSession: return Self.sshLoginProcess
        case .unknown: return nil
        }
    }

    /// The `next` line of a failed `--list`: which process needs the grant, and where to give it.
    /// The framework's own words ("The user declined TCCs …") do not say whose grant is missing,
    /// and "this binary" — what this line used to say — is the one answer that is never right.
    var grantAdvice: String {
        switch self {
        case let .terminalApp(program):
            return "grant Screen Recording to \(Self.shown(program)) in System Settings > Privacy "
                + "& Security > Screen Recording, then re-run"
        case .sshLoginSession:
            return "grant Screen Recording to \(Self.sshLoginProcess) (the process an SSH session "
                + "runs under) in System Settings > Privacy & Security > Screen Recording, then "
                + "reconnect and re-run"
        case .unknown:
            return "grant Screen Recording to the app krd was started from in System Settings > "
                + "Privacy & Security > Screen Recording, then re-run"
        }
    }

    /// The one line a refused capture says on stderr — and in the wall's footer, when a mirror hands
    /// the pane back with `--said`. The terminal case keeps the sentence it has always had: the
    /// reader is looking at that terminal, and a footer has one row. The SSH case cannot: there is no
    /// terminal there, so it names the process that actually answers.
    var deniedSentence: String {
        switch self {
        case .terminalApp, .unknown:
            return "Screen Recording is off for this terminal"
        case .sshLoginSession:
            return "Screen Recording is off for this SSH session - grant it to "
                + Self.sshLoginProcess + " in System Settings"
        }
    }
}

/// One picture of one panel, once — the landing screen's whole capture path.
///
/// `Capture.swift` is not touched from here on purpose. It owns the mirror's single long-lived
/// `SCStream`, and a stream's frame size is fixed when it starts, while the wall's panels differ in
/// size; so each panel is one `SCScreenshotManager` call instead of a stream (P0, measured
/// 2026-10-30 in the tart VM: a 1920×1200 display in 25.9 ms, windows in 18.3–28.7 ms, a whole
/// wall's four panels in 92.4 ms — once per change, not per frame). Nothing here keeps state
/// between calls, so there is no lifecycle to get wrong and no stream to restart.
struct PanelCapture {
    /// One picture of exactly one window, scaled by ScreenCaptureKit to the size asked for.
    /// The caller asks in the *content's* aspect (SCK scales to fit, anchored top-left, black
    /// padding otherwise - measured 2026-10-30), so no cropping happens here.
    static func window(id: CGWindowID, width: Int, height: Int) async throws -> CGImage {
        try await capture(width: width, height: height) { content in
            // No fallback to another window: the picture on a card is that window or a mask
            // (§6.6). Substituting a neighbour would be a wrong picture, which is worse than none.
            guard let window = find(id, in: content.windows, id: \.windowID) else {
                throw PanelCaptureError.windowGone
            }
            // A window's own pixels: its frame is in points, so the backing scale of the sharpest
            // screen is the most it can have. Asking for more is what produces black padding.
            let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            let native = CGSize(width: window.frame.width * scale,
                                height: window.frame.height * scale)
            return (SCContentFilter(desktopIndependentWindow: window), native)
        }
    }

    /// The same for a display.
    static func display(id: CGDirectDisplayID, width: Int, height: Int) async throws -> CGImage {
        try await capture(width: width, height: height) { content in
            // An id that is not in the list is a display that was unplugged or is asleep. There is
            // no `.displayGone` because a display is re-enumerated before it can be drawn at all:
            // the wall never holds a card for one it cannot find, so this is an id from a stale
            // model, not a panel that lost its picture.
            guard let display = find(id, in: content.displays, id: \.displayID) else {
                throw PanelCaptureError.failed("display \(id) is not in the shareable list")
            }
            let native = CGSize(width: display.width, height: display.height)
            return (SCContentFilter(display: display, excludingWindows: []), native)
        }
    }

    /// The largest request the source can actually answer, at the caller's aspect.
    ///
    /// **ScreenCaptureKit does not upscale**: asked for more pixels than the source has, it draws the
    /// source at its own size anchored top-left and pads the rest with black. A 1920x1200 display
    /// asked for a 2431x1518 picture therefore arrives as a 1920-wide desktop in the corner of a
    /// black canvas - which the reader sees as "the desktop fills only the top-left of the stage",
    /// and which gets *worse* the larger the picture is asked for (a 2x request would make the
    /// desktop occupy a quarter of the frame). So the request is capped here and the single upscale
    /// to the panel's exact pixels happens in `PanelRaster.rgb(_:width:height:)`.
    static func fitted(_ size: (w: Int, h: Int), within native: CGSize) -> (w: Int, h: Int) {
        guard native.width >= 1, native.height >= 1, size.w > 0, size.h > 0 else { return size }
        let scale = min(1, min(native.width / Double(size.w), native.height / Double(size.h)))
        guard scale < 1 else { return size }
        return (max(1, Int((Double(size.w) * scale).rounded())),
                max(1, Int((Double(size.h) * scale).rounded())))
    }

    /// First item whose id matches, or `nil`.
    ///
    /// `SCWindow` and `SCDisplay` have no public initialiser, so the rule itself is generic and
    /// `PanelCaptureTests` drives it with plain structs. What has to hold is that the id decides,
    /// the *first* duplicate wins (the list is already ordered front to back, so the first one is
    /// the window the reader pointed at), and a missing id never becomes a neighbour.
    static func find<T>(_ id: UInt32, in items: [T], id idOf: (T) -> UInt32) -> T? {
        for item in items where idOf(item) == id { return item }
        return nil
    }

    /// Enumerate, filter, shoot. Only the filter differs between a window and a display, so both
    /// callers share this rather than repeating the configuration and the error policy.
    private static func capture(width: Int, height: Int,
                                filter: (SCShareableContent) throws
                                    -> (SCContentFilter, CGSize)) async throws -> CGImage {
        do {
            // The same list the wall's cards come from, for the same reason: a window that is not
            // on screen is not a card, so it is not captured either.
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                              onScreenWindowsOnly: true)
            let (filter, native) = try filter(content)
            let asked = fitted((width, height), within: native)
            if asked.w != width || asked.h != height {
                // Worth a line, because the picture will now be upscaled by us instead: this is the
                // path that used to arrive as a black canvas with the desktop in one corner.
                Log.write("krd: capture \(width)x\(height) px asked, \(asked.w)x\(asked.h) px from a "
                          + "\(Int(native.width))x\(Int(native.height)) px source\n")
            }
            let configuration = SCStreamConfiguration()
            configuration.width = asked.w
            configuration.height = asked.h
            configuration.showsCursor = false
            // The scale is deliberately left alone: `pointPixelScale` would turn `width`/`height`
            // from the picture's size into a hint, and the measured fit (aspect kept, anchored
            // top-left, black padding) is exactly what the caller already compensated for.

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: configuration)
            // The async import hands back a non-optional image, so the one unusable picture left
            // is an empty one; tiles and the encoder assume at least one pixel and would trap.
            guard image.width > 0, image.height > 0 else { throw PanelCaptureError.noPixelBuffer }
            return image
        } catch {
            throw classify(error)
        }
    }

    /// One policy for all four failure modes, so a caller only ever sees `PanelCaptureError` and a
    /// panel's mask never depends on which of the calls happened to fail.
    ///
    /// The numbers are `SCStreamErrorDomain`'s (`SCError.h`); anything else — a `CGError`, an
    /// error we threw ourselves — keeps its message and loses only its type.
    static func classify(_ error: Error) -> PanelCaptureError {
        // Already ours: the catch in `capture` re-classifies, and a test may hand one straight in.
        if let known = error as? PanelCaptureError { return known }
        let ns = error as NSError
        // The code alone proves nothing: `-3801` in another domain is some other refusal.
        guard ns.domain == SCStreamErrorDomain else { return .failed(ns.localizedDescription) }
        switch ns.code {
        case -3801:
            // SCStreamErrorUserDeclined: the TCC answer, or a picker the user cancelled. No retry
            // will help until the reader opens System Settings, which is not this function's news.
            return .denied
        case -3803:
            // SCStreamErrorMissingEntitlements: the same answer with no dialog in between.
            return .denied
        case -3813:
            // SCStreamErrorNoWindowList: the window left between enumeration and the shot — the
            // one failure the capture call itself reports as "gone" rather than as a policy.
            return .windowGone
        default:
            // -3802 / -3804 (failed to start, connection invalid) land here: a transient fault is
            // worth a retry on the next tick, so it must not be mistaken for a permission answer.
            return .failed(ns.localizedDescription)
        }
    }
}
