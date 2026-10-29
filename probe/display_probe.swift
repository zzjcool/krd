// Does a display change reach this process, and which way?
//
// Written while fixing issue #19, because two plausible mechanisms both failed and neither is
// documented that way:
//
//   swift probe/display_probe.swift now          # current mode
//   swift probe/display_probe.swift list         # every mode this display offers
//   swift probe/display_probe.swift set 2        # apply mode 2 (a real resolution change)
//   swift probe/display_probe.swift watch        # watch for 10 s, printing both mechanisms
//   swift probe/display_probe.swift watch --appkit   # same, but with NSApp.run()
//
// Measured on macOS 26 over ssh: `watch` prints nothing at all (no CoreGraphics callback),
// `watch --appkit` prints three `notification` lines per resolution change. That is why krd also
// polls the display set instead of trusting the event.

import AppKit
import CoreGraphics
import Foundation

let display = CGMainDisplayID()

func current() -> String {
    let bounds = CGDisplayBounds(display)
    return "\(CGDisplayPixelsWide(display))x\(CGDisplayPixelsHigh(display)) px, "
        + "bounds \(Int(bounds.width))x\(Int(bounds.height)) at \(Int(bounds.minX)),\(Int(bounds.minY))"
}

func modes() -> [CGDisplayMode] {
    let options = [kCFBooleanTrue: kCGDisplayShowDuplicateLowResolutionModes] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
}

var args = Array(CommandLine.arguments.dropFirst())
let appkit = args.contains("--appkit")
args.removeAll { $0.hasPrefix("--") }
let verb = args.first ?? "now"

switch verb {
case "now":
    print(current())

case "list":
    for (index, mode) in modes().enumerated() {
        print("\(index)\t\(mode.width)x\(mode.height)\t\(mode.pixelWidth)x\(mode.pixelHeight) px"
            + "\t\(mode.refreshRate) Hz")
    }

case "set":
    let all = modes()
    guard args.count > 1, let index = Int(args[1]), index >= 0, index < all.count else {
        print("usage: display_probe.swift set <index from `list`>")
        exit(2)
    }
    var raw: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&raw) == .success, let config = raw else {
        print("CGBeginDisplayConfiguration failed")
        exit(1)
    }
    let set = CGConfigureDisplayWithDisplayMode(config, display, all[index], nil)
    let done = CGCompleteDisplayConfiguration(config, .permanently)
    print("set=\(set.rawValue) done=\(done.rawValue) -> \(all[index].width)x\(all[index].height)")
    print("now: \(current())")

case "watch":
    print("watching for display changes for 10 s (appkit run loop: \(appkit)) — change the resolution now")
    let callback: CGDisplayReconfigurationCallBack = { display, flags, _ in
        print("callback  display=\(display) flags=\(flags.rawValue)")
        fflush(stdout)
    }
    CGDisplayRegisterReconfigurationCallback(callback, nil)
    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
        print("notification")
        fflush(stdout)
    }
    if appkit {
        // Only NSApp's run loop posts didChangeScreenParameters; a plain RunLoop.main.run()
        // gets the CoreGraphics callback (in the Aqua session) and no notification.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
        app.run()
    } else {
        RunLoop.main.run(until: Date().addingTimeInterval(10))
    }
    print("done: \(current())")

default:
    print("usage: display_probe.swift [now | list | set <index> | watch [--appkit]]")
    exit(2)
}
