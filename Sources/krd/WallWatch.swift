import AppKit
import Foundation

/// The wall's world watcher: the events the system actually reports when the window list can move.
///
/// This is the trigger that replaced the 1 s enumeration (issue #141). It exists because the
/// *answer* to "did anything change?" is only worth paying for when the answer can be yes, and
/// AppKit already knows when that is:
///
/// - an app launched or quit (a regular app's windows can appear or vanish — `WindowOrder` filters
///   by `regularPIDs`, so this is exactly the set that can change the list's membership),
/// - an app was activated or deactivated (the list is front-to-back, so the *order* changes with
///   focus),
/// - an app was hidden or unhidden (`optionOnScreenOnly` drops a hidden app's windows),
/// - the active space changed (the on-screen set is per-space),
/// - the display configuration changed (`NSScreen.screens` and the stage's aspect).
///
/// A new window inside an app that is *already* frontmost while the wall's terminal sits behind it
/// is the one case AppKit does not announce; it is reconciled by the next trigger, and the wall's
/// own input goes through that same trigger before it hit-tests a click. The alternative — a
/// per-second enumeration that throws its answer away — is the bug this file removes (issue #141:
/// 1.24 ms median / 1.52 ms p95 of wall time, every second, to conclude `unchanged`).
final class WallWatch {
    private var tokens: [NSObjectProtocol] = []

    /// `onWorldChange` runs on the main queue, coalesced: a launch posts several notifications in a
    /// row (activate + launch), and a window that is still being created when the first one lands
    /// must not be missed. The delay is the whole reason the refresh is not immediate.
    func start(coalescing delay: TimeInterval = 0.08, onWorldChange: @escaping () -> Void) {
        stop()
        var pending: DispatchWorkItem?
        let fire: () -> Void = {
            pending?.cancel()
            let work = DispatchWorkItem(block: onWorldChange)
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                // `queue: .main` means this already runs on the main queue, so the work item below
                // is ordered after the notification that caused it.
                fire()
            })
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in fire() })
    }

    func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        for token in tokens { workspace.removeObserver(token); NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }

    deinit { stop() }
}
