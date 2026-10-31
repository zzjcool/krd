#!/usr/bin/env python3
"""How many keystrokes does a byte sequence produce, and how many replies does it parse?

A harness for the terminal-input parser (`Sources/krdcore/Input.swift`, `InputParser`), driven with
a **fake clock** and no terminal at all. It drives the parser exactly the way
`InputReader.loop()` (`Sources/krd/Input.swift`) drives it:

    poll(stdin, 100 ms) --timeout--> resolveStall(now:)        --data--> feed(bytes, now:)

so the decisions it measures are the decisions a pty would drive: the 100 ms poll timeout is the
only clock the idle decisions run on, and every read is one `feed`. Nothing here opens a terminal,
sleeps, or reads the wall clock, so the same bytes and the same clock marks give the same table on
any machine -- which is the one property this harness needs, because it is run before and after a
parser fix.

Why not the pty route: `swift build -c release` plus `krd --dev-selftest --debug` under a
`pty.fork` (the idiom in `probe/pipe_probe.py` and `bench/wire.py`) would measure the same parser
*through* real sleeps, frame rendering and injection into a target process. The numbers would
depend on scheduling, and the keystroke count would have to be read out of `--debug` trace lines
(`raw N bytes: …`, `text "h" injected`, `graphic reply ok image=…`, and `.notice` -> `log(text)`).
`krdcore` is platform-neutral on purpose (Package.swift: "no screen, no terminal, no tty") and
`resolveStall(now:)` exists so the idle policy "can be tested against a fake clock" -- that is the
route taken here, and it measures the same state machine.

Usage:

    python3 probe/reply_stage.py                    # the working tree
    python3 probe/reply_stage.py --from-git HEAD     # a revision, for the before/after pair
    python3 probe/reply_stage.py --trace             # ... plus each stage's canonical event trace
    python3 probe/reply_stage.py --strict            # exit 1 if a stage misses its expectation

The stages (A-G are the contract; H-K are the two bugs this is meant to catch -- a reply's late
tail typed as keys, and a discard whose 1500 ms deadline a typist can starve):

    A  "hi"                                  -> 2 keys
    B  ESC _ G i=31;OK ST                    -> 1 reply, 0 keys
    C  ESC _ , +300 ms, "hello"              -> Alt+_ h e l l o (6 keys)
    D  ESC _ , +1200 ms, Gi=31;OK ST         -> 1 reply, 0 keys
    E  ESC _ , +1600 ms, Gi=31;OK ST         -> 1 reply, 0 keys
    F  ESC ] , +300 ms, "hello"              -> Alt+] h e l l o (6 keys)
    G  ESC ] , 15x"a" @200 ms                -> Alt+] and all 15 keys
    H  ESC _ G i=31; , +1700 ms, SECRET ST   -> 0 keys (7 before the fix: the tail was typed)
    I  ESC ] 52;c; , +1700 ms, SECRET ST     -> 0 keys (7 before the fix)
    J  ESC ] 52;c;AAAA, 60x"a" @50 ms        -> bounded at 1500 ms: keys past it are typed
    K  ESC ] 52;c;X, idle 100 ms ticks       -> the discard ends after 1500 ms, not 3440

`ESC`/`ST` are the two-byte sequences `1b` and `1b 5c`; the spaces in the table above are
spelling. The parser source is compiled with the harness by `swiftc` (no package build), so a run
is a compile plus a millisecond of measurement.
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

# The parser and the two pure tables it needs. Deliberately not `Sources/krdcore/*.swift`:
# `Render.swift` reaches for CZlib, and nothing below needs a screen, a frame or a clock.
PARSER_FILES = (
    "Sources/krdcore/Input.swift",
    "Sources/krdcore/Keyboard.swift",
    "Sources/krdcore/Keys.swift",
)

# `feed` gained the read's clock in the round that made the deadline check run on every read
# (issue #109). Both generations must be measurable -- the point of the harness is the pair.
FEED_ADAPTER = {
    "with-clock": r'''
/// This parser's `feed` takes the read's clock, so the harness hands it the fake one: the deadline
/// is checked *inside* `feed`, and without the fake `now` that check would read the wall clock and
/// stage J ("a typist cannot starve the check") would measure nothing.
@inline(__always) func feedAt(_ parser: InputParser, _ bytes: [UInt8], _ t: Double) {
    parser.feed(bytes, now: t)
}
''',
    "bytes-only": r'''
/// This parser's `feed` takes bytes only: its deadline is checked on the idle tick alone, which is
/// exactly the window stage J measures (a typist arriving faster than 100 ms starves it).
@inline(__always) func feedAt(_ parser: InputParser, _ bytes: [UInt8], _ t: Double) {
    parser.feed(bytes)
}
''',
}

REPORT_ADAPTER = {
    "with-report": r'''
/// The parser's own account of the discard that ended last (`InputParser.lastDiscard`).
func parserDiscardReport(_ parser: InputParser) -> String {
    guard let report = parser.lastDiscard else { return "" }
    let who = report.introducer == .osc ? "OSC" : "APC-G"
    return "parser: \(who) ended at \(String(describing: report.end)),"
        + " \(report.dropped) B dropped, \(Int(report.livedMs)) ms"
}
''',
    "no-report": r'''
/// No `lastDiscard` in this generation: the harness's own latch/end marks are the only report.
func parserDiscardReport(_ parser: InputParser) -> String { "" }
''',
}

SWIFT = r'''// GENERATED by probe/reply_stage.py -- edit that file, not this one.
//
// A fake-clock harness for the terminal-input parser (`Sources/krdcore/Input.swift`). It drives
// `InputParser` the way `InputReader.loop()` drives it:
//
//     poll(stdin, 100 ms) --timeout--> resolveStall(now:)      --data--> feed(bytes, now:)
//
// and counts what a session sees: the events that reach the mirrored desktop ("keys"), the
// `.graphicReply` events ("replies") and the `.notice` events. No terminal, no display, no sleep:
// every clock mark is passed in, so the run is deterministic.

import Foundation

/// The parser's default arguments name the wall clock. Every call below passes the fake one, so
/// this stub is never consulted for a decision (it also stands in for `Render.swift`'s
/// `benchNowMs`, which is not compiled here because `bench` has no business in a parser harness).
@inline(__always) public func benchNowMs() -> Double { 0 }

// MARK: - per parser generation

__FEED_ADAPTER__

__REPORT_ADAPTER__

// MARK: - what the parser said

/// Everything that reaches the mirrored desktop: a key report, a resolved press, text, a control
/// byte. The same predicate `Tests/krdcoreTests/GraphicsReplyTests.swift` calls `injected()`.
func isInput(_ event: Event) -> Bool {
    switch event {
    case .key, .press, .text, .control: return true
    case .mouse, .osc, .keyboardFlags, .statusReport, .graphicReply, .notice: return false
    }
}

func inputEvents(_ events: [Event]) -> [Event] { events.filter(isInput) }

func replyEvents(_ events: [Event]) -> [GraphicsReply] {
    events.compactMap { if case let .graphicReply(reply) = $0 { return reply } else { return nil } }
}

func noticeTexts(_ events: [Event]) -> [String] {
    events.compactMap { if case let .notice(text) = $0 { return text } else { return nil } }
}

/// One keystroke, compactly: `h`, `^h` (Alt), `<53>` for a key code, `key(97)` for a report.
func describe(_ event: Event) -> String {
    switch event {
    case let .text(ch, mods):
        return mods.contains(.maskAlternate) ? "^\(ch)" : "\(ch)"
    case let .press(code, mods, _):
        return "\(mods.contains(.maskAlternate) ? "^" : "")<\(code)>"
    case let .key(report):
        return "key(\(report.code)\(report.mods == 0 ? "" : ",m\(report.mods)"))"
    case let .control(byte):
        return "ctl(\(byte))"
    default:
        return "-"
    }
}

func typedSummary(_ events: [Event]) -> String {
    let typed = inputEvents(events).map(describe)
    return typed.isEmpty ? "nothing" : typed.joined(separator: " ")
}

/// Everything the parser said, one line: the keys, every reply (quoted, so a payload is visible)
/// and every notice. A notice is a diagnostic sentence, so it is shortened here; `--trace` prints
/// it in full (and every event's `canonicalTrace`).
func shortNotice(_ text: String) -> String {
    text.count <= 56 ? text : String(text.prefix(52)) + "..."
}

func summary(_ events: [Event]) -> String {
    var parts: [String] = ["keys: " + typedSummary(events)]
    for reply in replyEvents(events) {
        parts.append("reply: body=\(reply.body.debugDescription)"
                     + " i=\(reply.image.map(String.init) ?? "-")"
                     + " status=\(reply.status.debugDescription)")
    }
    for text in noticeTexts(events) { parts.append("notice: \(shortNotice(text).debugDescription)") }
    return parts.joined(separator: "; ")
}

// MARK: - one scripted run

/// One scripted run: bytes at a mark, idle ticks between marks.
///
/// The 100 ms poll is emulated the way it behaves on a pty: a tick fires only when the next byte is
/// *further away* than 100 ms -- data that lands on a tick mark is what `poll` returns first, so it
/// preempts the timeout. That is the whole timing model, and it is why the table is repeatable.
final class Sim {
    private let parser = InputParser()
    private(set) var events: [Event] = []
    /// The mark the first keystroke reached the desktop at (nil when nothing was typed).
    private(set) var firstKeyAt: Double?
    /// Every keystroke-arrival mark (`feedKey`), i.e. the typing stages' input.
    private(set) var keysFedAt: [Double] = []
    private(set) var ticks: [Double] = []
    private(set) var discardLatchAt: Double?
    private(set) var discardEndAt: Double?
    private var now: Double = 0
    private var lastReadAt: Double = 0

    init() {
        parser.onEvent = { [unowned self] event in
            self.events.append(event)
            if self.firstKeyAt == nil, isInput(event) { self.firstKeyAt = self.now }
        }
    }

    /// Bytes arrive at `t`.
    func feed(_ text: String, at t: Double) { feed(Array(text.utf8), at: t) }

    func feed(_ bytes: [UInt8], at t: Double) {
        ticksBefore(t)
        now = t
        lastReadAt = t
        feedAt(parser, bytes, t)
        observe()
    }

    /// Bytes arrive at `t` and they are a keystroke (counted as one of the stage's keys).
    func feedKey(_ text: String, at t: Double) {
        keysFedAt.append(t)
        feed(text, at: t)
    }

    /// Nothing arrives until `t`: the poll timeout fires as often as it fits in the gap.
    func idle(until t: Double) {
        ticksBefore(t)
        now = t
        observe()
    }

    /// Idle until the open discard ends, so a lifetime stage can report where it ended.
    func idleUntilDiscardEnds(limit: Double) {
        while true {
            let next = lastReadAt + 100
            guard next < limit else { now = limit; return }
            tick(at: next)
            if discardEndAt != nil { return }
        }
    }

    /// `latch->end (life)` in ms, or nil when no discard ever opened.
    var discardSpan: String? {
        guard let latch = discardLatchAt else { return nil }
        guard let end = discardEndAt else { return "\(Int(latch))->open" }
        return "\(Int(latch))->\(Int(end)) (\(Int(end - latch)))"
    }

    var discardLife: Double? {
        guard let latch = discardLatchAt, let end = discardEndAt else { return nil }
        return end - latch
    }

    var parserReport: String { parserDiscardReport(parser) }

    private func ticksBefore(_ limit: Double) {
        while lastReadAt + 100 < limit { tick(at: lastReadAt + 100) }
    }

    private func tick(at t: Double) {
        now = t
        lastReadAt = t
        ticks.append(t)
        _ = parser.resolveStall(now: t)
        observe()
    }

    /// Latch and end of the open discard, as this side of the boundary sees them: `isDiscarding`
    /// flips during the tick or read at `now`.
    private func observe() {
        if parser.isDiscarding {
            if discardLatchAt == nil { discardLatchAt = now }
        } else if discardLatchAt != nil, discardEndAt == nil {
            discardEndAt = now
        }
    }
}

struct Stage {
    let id: String
    let scenario: String
    let script: (Sim) -> Void
    let check: (Sim) -> (ok: Bool, expected: String, note: String)
}

/// `; parser: …` — the parser's own account of the discard, appended when it reports one.
func discardSuffix(_ sim: Sim) -> String {
    let report = sim.parserReport
    return report.isEmpty ? "" : "; " + report
}

// MARK: - the stages

let allFifteenKeys = (["^]"] + Array(repeating: "a", count: 15)).joined(separator: " ")

let stages: [Stage] = [
    Stage(id: "A", scenario: "\"hi\" (one read)",
          script: { sim in sim.feed("hi", at: 0) },
          check: { sim in
              let got = typedSummary(sim.events)
              return (got == "h i", "keys = 2", "keys: \(got)")
          }),

    Stage(id: "B", scenario: "ESC _ G i=31;OK ST (one read)",
          script: { sim in sim.feed("\u{1B}_Gi=31;OK\u{1B}\\", at: 0) },
          check: { sim in
              let replies = replyEvents(sim.events)
              let ok = inputEvents(sim.events).isEmpty && replies.count == 1
                  && replies.first?.image == 31 && replies.first?.status == "OK"
              return (ok, "0 keys, 1 reply (i=31 OK)", summary(sim.events))
          }),

    Stage(id: "C", scenario: "ESC _ , +300 ms, \"hello\"",
          script: { sim in
              sim.feed("\u{1B}_", at: 0)
              sim.idle(until: 300)
              sim.feed("hello", at: 300)
          },
          check: { sim in
              let got = typedSummary(sim.events)
              return (got == "^_ h e l l o", "keys 6: Alt+_ h e l l o", "keys: \(got)")
          }),

    Stage(id: "D", scenario: "ESC _ , +1200 ms, Gi=31;OK ST",
          script: { sim in
              sim.feed("\u{1B}_", at: 0)
              sim.idle(until: 1200)
              sim.feed("Gi=31;OK\u{1B}\\", at: 1200)
          },
          check: { sim in
              let replies = replyEvents(sim.events)
              let ok = inputEvents(sim.events).isEmpty && replies.count == 1
                  && replies.first?.body == "Gi=31;OK"
              return (ok, "0 keys, 1 reply (body Gi=31;OK)", summary(sim.events))
          }),

    Stage(id: "E", scenario: "ESC _ , +1600 ms, Gi=31;OK ST",
          script: { sim in
              sim.feed("\u{1B}_", at: 0)
              sim.idle(until: 1600)
              sim.feed("Gi=31;OK\u{1B}\\", at: 1600)
          },
          check: { sim in
              let replies = replyEvents(sim.events)
              let ok = inputEvents(sim.events).isEmpty && replies.count == 1
                  && replies.first?.body == "Gi=31;OK"
              return (ok, "0 keys, 1 reply (body Gi=31;OK)", summary(sim.events))
          }),

    Stage(id: "F", scenario: "ESC ] , +300 ms, \"hello\"",
          script: { sim in
              sim.feed("\u{1B}]", at: 0)
              sim.idle(until: 300)
              sim.feed("hello", at: 300)
          },
          check: { sim in
              let got = typedSummary(sim.events)
              return (got == "^] h e l l o", "keys 6: Alt+] h e l l o", "keys: \(got)")
          }),

    Stage(id: "G", scenario: "ESC ] , 15x\"a\" @200 ms",
          script: { sim in
              sim.feed("\u{1B}]", at: 0)
              for i in 1...15 { sim.feedKey("a", at: Double(i) * 200) }
          },
          check: { sim in
              let got = typedSummary(sim.events)
              return (got == allFifteenKeys, "keys 16: Alt+] and all 15",
                      "keys: \(got); \(sim.keysFedAt.count) typed at 200 ms apart")
          }),

    // Bug 1: a reply whose tail arrives after the discard's deadline. The tail *completes* the
    // sequence (`SECRET` then `ST`), so it is the reply's own ending arriving late -- not input.
    Stage(id: "H", scenario: "ESC _ G i=31; , +1700 ms, SECRET ST",
          script: { sim in
              sim.feed("\u{1B}_Gi=31;", at: 0)
              sim.idle(until: 1700)
              sim.feed("SECRET\u{1B}\\", at: 1700)
          },
          check: { sim in
              let ok = inputEvents(sim.events).isEmpty
              return (ok, "keys 0 (the late tail is the reply's)",
                      summary(sim.events) + discardSuffix(sim))
          }),

    Stage(id: "I", scenario: "ESC ] 52;c; , +1700 ms, SECRET ST",
          script: { sim in
              sim.feed("\u{1B}]52;c;", at: 0)
              sim.idle(until: 1700)
              sim.feed("SECRET\u{1B}\\", at: 1700)
          },
          check: { sim in
              let ok = inputEvents(sim.events).isEmpty
              return (ok, "keys 0 (the late tail is the reply's)",
                      summary(sim.events) + discardSuffix(sim))
          }),

    // Bug 2: the deadline is checked on the idle tick only, so bytes arriving faster than the tick
    // starve it. Latch a discard, then type at 50 ms for 3000 ms.
    Stage(id: "J", scenario: "ESC ] 52;c;AAAA, 60x\"a\" @50 ms",
          script: { sim in
              sim.feed("\u{1B}]52;c;AAAA", at: 0)
              sim.idle(until: 100)                        // the tick that latches the discard
              for i in 1...60 { sim.feedKey("a", at: 100 + Double(i) * 50) }
              sim.idle(until: 6000)                       // let a discard that is still open end
          },
          check: { sim in
              let typed = inputEvents(sim.events).count
              let keys = sim.keysFedAt
              let latch = sim.discardLatchAt ?? 0
              let boundary = latch + 1500                 // where the 1500 ms deadline falls
              let afterBoundary = keys.filter { $0 >= boundary }.count
              let life = sim.discardLife
              let bounded = life.map { $0 >= 1500 && $0 <= 1600 } ?? false
              let ok = bounded && typed > 0 && abs(typed - afterBoundary) <= 1
              var note = "\(typed) of \(keys.count) keys typed, \(keys.count - typed) eaten"
              if let first = sim.firstKeyAt {
                  note += "; first key at t=\(Int(first))"
              }
              note += "; deadline at t=\(Int(boundary)) (\(afterBoundary) keys land past it)"
              return (ok, "bounded in 1500 ms: keys past it typed", note + discardSuffix(sim))
          }),

    // The anchored deadline, on its own: nothing but idle ticks, so nothing but the clock decides.
    Stage(id: "K", scenario: "ESC ] 52;c;X, idle 100 ms ticks",
          script: { sim in
              sim.feed("\u{1B}]52;c;X", at: 0)
              sim.idleUntilDiscardEnds(limit: 6000)
          },
          check: { sim in
              let latch = sim.discardLatchAt ?? -1
              let end = sim.discardEndAt ?? -1
              let life = sim.discardLife ?? -1
              let ok = latch >= 0 && end >= 0 && life >= 1500 && life <= 1600
              let note = "discard \(sim.discardSpan ?? "-") ms"
                  + "; \(Int(life)) ms of life, ended \(Int(end)) ms after the first byte"
              return (ok, "life = 1500 ms, not 3440", note + discardSuffix(sim))
          }),
]

// MARK: - the table

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, width - text.count))
    return right ? fill + text : text + fill
}

let trace = CommandLine.arguments.contains("--trace")
let strict = CommandLine.arguments.contains("--strict")

print("clock   : fake; a poll tick fires 100 ms after the last read, only when the next byte is"
      + " further away than that")
print("keys    : .key/.press/.text/.control (what reaches the desktop)"
      + "   replies: .graphicReply   notices: .notice")
print("clock marks: a tick that latches a discard is its anchor; `discard:` is latch->end (life)")
print("")

var rows: [[String]] = []
var failures: [String] = []
var traces: [(String, String)] = []

for stage in stages {
    let sim = Sim()
    stage.script(sim)
    let (ok, expected, note) = stage.check(sim)
    if !ok { failures.append(stage.id) }
    rows.append([stage.id, stage.scenario,
                 "\(inputEvents(sim.events).count)",
                 "\(replyEvents(sim.events).count)",
                 "\(noticeTexts(sim.events).count)",
                 "\(sim.ticks.count)",
                 sim.discardSpan.map { "\($0)" } ?? "-",
                 ok ? "PASS" : "FAIL",
                 expected, note])
    if trace {
        let lines = sim.events.map(\.canonicalTrace).joined(separator: " | ")
        traces.append((stage.id, lines.isEmpty ? "(no events)" : lines))
    }
}

let header = ["stage", "scenario", "keys", "rply", "ntc", "tick", "discard latch->end (ms)",
              "verdict", "expected", "note"]
var widths = header.map(\.count)
for row in rows {
    for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
}
func line(_ cells: [String]) -> String {
    cells.enumerated().map { pad($0.element, widths[$0.offset]) }.joined(separator: "  ")
}
print(line(header))
print(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
for row in rows { print(line(row)) }

if trace {
    print("")
    for (id, events) in traces { print("trace \(id): \(events)") }
}

print("")
let passed = stages.count - failures.count
print("\(stages.count) stages, \(passed) pass, \(failures.count) fail"
      + (failures.isEmpty ? "" : ": " + failures.joined(separator: " ")))
if strict && !failures.isEmpty { exit(1) }
'''


def sha256(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(command, timeout):
    """Run `command`, never waiting longer than `timeout`."""
    return subprocess.run(command, capture_output=True, text=True,
                          timeout=timeout, check=False)


def extract(root, rev, work):
    """`git show rev:path` for each parser file, so a revision can be measured as it was."""
    out = os.path.join(work, "from-git")
    os.makedirs(out, exist_ok=True)
    paths = []
    for name in PARSER_FILES:
        shown = run(["git", "-C", root, "show", "{}:{}".format(rev, name)], timeout=60)
        if shown.returncode != 0:
            sys.exit("cannot read {} at {}: {}".format(name, rev, shown.stderr.strip()))
        target = os.path.join(out, os.path.basename(name))
        with open(target, "w") as handle:
            handle.write(shown.stdout)
        paths.append(target)
    return paths


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Measure keystrokes and graphic replies for a set of byte sequences.",
        epilog="the parser is compiled by swiftc and driven with a fake clock; no terminal, no "
               "display, no sleeps.")
    parser.add_argument("--from-git", metavar="REV",
                        help="measure Sources/krdcore/*.swift at REV instead of the working tree")
    parser.add_argument("--swiftc", default="swiftc", help="compiler to use (default: swiftc)")
    parser.add_argument("--work", default=os.path.join(tempfile.gettempdir(), "krd-reply-stage"),
                        help="where the generated source and the binary go")
    parser.add_argument("--timeout", type=float, default=300.0,
                        help="hard limit for the compile and for the run, in seconds")
    parser.add_argument("--trace", action="store_true",
                        help="also print each stage's canonical event trace")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 when a stage misses its expectation")
    parser.add_argument("--extra-source", action="append", default=[], metavar="PATH",
                        help="compile one more Swift file (a new krdcore dependency, say)")
    args = parser.parse_args(argv)

    root = repo_root()
    os.makedirs(args.work, exist_ok=True)

    if args.from_git:
        sources = extract(root, args.from_git, args.work)
        state = "git rev {}".format(args.from_git)
    else:
        sources = [os.path.join(root, name) for name in PARSER_FILES]
        state = "working tree"
    sources += [os.path.abspath(path) for path in args.extra_source]

    for path in sources:
        if not os.path.exists(path):
            sys.exit("missing parser source: {}".format(path))

    # Which `feed` does this parser have? One grep decides, and the compile proves it.
    parser_source = next(path for path in sources
                         if os.path.basename(path) == "Input.swift")
    with open(parser_source) as handle:
        text = handle.read()
    feed = "with-clock" if "func feed(_ bytes: [UInt8], now:" in text else "bytes-only"
    report = "with-report" if "public private(set) var lastDiscard" in text else "no-report"

    harness = os.path.join(args.work, "main.swift")
    with open(harness, "w") as handle:
        handle.write(SWIFT.replace("__FEED_ADAPTER__", FEED_ADAPTER[feed].strip("\n"))
                     .replace("__REPORT_ADAPTER__", REPORT_ADAPTER[report].strip("\n")))

    binary = os.path.join(args.work, "reply_stage")
    command = [args.swiftc, "-O", "-swift-version", "5"] + sources + [harness, "-o", binary]
    try:
        built = run(command, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        sys.exit("swiftc did not finish within {} s".format(args.timeout))
    if built.returncode != 0:
        sys.stderr.write("swiftc failed:\n{}\n{}\n".format(" ".join(command), built.stderr))
        sys.exit(1)

    print("krd reply-stage probe -- keystrokes and graphic replies from the input parser")
    print("parser  : {}".format(state))
    for path in sources:
        print("          {}  {}".format(sha256(path)[:16], os.path.basename(path)))
    if args.from_git is None:
        dirty = run(["git", "-C", root, "status", "--porcelain", "--"] + list(PARSER_FILES),
                    timeout=60)
        print("git     : {} {}".format(
            run(["git", "-C", root, "rev-parse", "--short", "HEAD"], timeout=60).stdout.strip(),
            "(dirty: {})".format(dirty.stdout.strip().replace("\n", ", "))
            if dirty.stdout.strip() else "(clean)"))
    print("build   : swiftc -O -swift-version 5 (feed: {}, report: {})".format(feed, report))
    print("")

    argv_binary = [binary] + ([("--trace")] if args.trace else []) + (["--strict"]
                                                                     if args.strict else [])
    try:
        result = subprocess.run(argv_binary, capture_output=True, text=True,
                                timeout=args.timeout, check=False)
    except subprocess.TimeoutExpired:
        sys.exit("the harness did not finish within {} s".format(args.timeout))
    sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stdout.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
