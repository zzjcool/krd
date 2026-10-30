// kagent-driver — the two capabilities an agent has to borrow from a real Mac: eyes and hands.
//
//   kagent-driver shot  [--out path] [--window ID] [--rect x,y,w,h] [--max-width N]
//                       [--grid N] [--marks file.json] [--cursor] [--format jpeg|png]
//   kagent-driver input <click|move|down|up|drag|scroll|type|key|sleep> ...
//
// Everything is one process per call on purpose: it starts in ~20 ms, needs no daemon, and its exit
// code distinguishes "the app ignored me" (0) from "macOS never showed me the event" (3). That
// difference is what keeps an unattended run from reporting a green test on a machine where
// nothing happened at all.

import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
guard let first = argv.first, !first.hasPrefix("--") else {
    fail(EXIT_USAGE, """
        usage: kagent-driver <shot|input|windows> [options]

          shot                      capture the screen (or a window, or a rect) as a JPEG + metadata
            --out <path>              where to write the frame (default /tmp/kagent-shot.jpg)
            --window <id>             CGWindowID; `krd ax windows --json` prints none, so use
                                      `kagent windows` which does
            --rect <x,y,w,h>          capture a region instead of the whole display
            --max-width <n>           delivered width in pixels (default 1200)
            --grid <n>                draw a labelled grid every n capture pixels
            --marks <file.json>       draw numbered boxes from [{"n":1,"rect":[x,y,w,h],...}]
            --cursor                  draw a crosshair where the pointer is
            --format jpeg|png         delivery format (default jpeg)
            --quality <0..1>          JPEG quality (default 0.72)

          input <verb> ...          post CGEvents at global display points (y down)

          windows                   on-screen windows with their CGWindowID and rect

          probe <x> <y>             the colour at a screen point, as #rrggbb
        """)
}

let args = Args(argv)

switch args.verb {
case "shot", "capture":
    runShot(args)
case "windows", "win":
    runWindows(args)
case "probe":
    runProbe(args)
case "input":
    var inner = args
    guard let next = inner.positional.first else {
        fail(EXIT_USAGE, "input needs a verb, e.g. `kagent-driver input click 812 340`")
    }
    inner.verb = next
    inner.positional.removeFirst()
    runInput(inner)
default:
    fail(EXIT_USAGE, "unknown command \(args.verb) (shot, input)")
}
