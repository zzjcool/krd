import Foundation
import CoreGraphics
import ScreenCaptureKit

print("screenCapturePreflight:", CGPreflightScreenCaptureAccess())
print("postEventPreflight:", CGPreflightPostEventAccess())
print("displayScale(screen):", NSScreen.main?.backingScaleFactor ?? -1)

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        print("displays:", c.displays.count, "windows:", c.windows.count)
        for d in c.displays { print("  display \(d.displayID): \(d.width)x\(d.height)") }
        let apps = Set(c.windows.compactMap { $0.owningApplication?.applicationName })
        print("  apps:", apps.sorted().prefix(8).joined(separator: ", "))
        if let w = c.windows.first(where: { $0.windowLayer == 0 && $0.frame.width > 300 }) {
            print("  window-level sample: \"\(w.title ?? "-")\" \(Int(w.frame.width))x\(Int(w.frame.height)) app=\(w.owningApplication?.applicationName ?? "-")")
        }
    } catch { print("SCK error:", error) }
    sem.signal()
}
sem.wait()
