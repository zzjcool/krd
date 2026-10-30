import Foundation
import XCTest
@testable import krd
import krdcore

/// Red tests for the wall's text layer against **another app's string**.
///
/// The hypothesis under test: a window title is untrusted input that arrives from
/// `CGWindowListCopyWindowInfo` (via `WindowOrder`, which only drops all-whitespace titles and
/// returns real ones untrimmed) and goes into the cell grid through `DisplayWidth`, which is a
/// *width* table and knows nothing about control scalars. `DisplayWidth.of("\n")` is 1 and
/// `DisplayWidth.of("\u{1B}")` is 1, so `Grid.set` stores them like any other one-cell glyph and
/// `render` sends them verbatim inside a positioned run. That would break `WallCanvas`'s own write
/// invariant 1 ("this file never emits `\n`": a newline on the last row scrolls the grid and puts
/// every kitty placement one row off) and would let a title inject an arbitrary escape sequence
/// from another process into the pane.
///
/// These tests do not fix anything - they pin what the painter does today so the fix has something
/// to turn green. Each one names the invariant it is measuring.
final class BugWallTextTests: XCTestCase {
    // MARK: - the fixed pane and model

    private let cols = 137
    private let rows = 44
    private let cellW: Double = 8
    private let cellH: Double = 16

    private func window(_ i: Int, title: String?) -> OrderedWindow {
        OrderedWindow(windowID: UInt32(1000 + i), pid: Int32(2000 + i), app: "App\(i)",
                      title: title,
                      bounds: CGRectCompat(x: 0, y: 0, width: 1440, height: 900))
    }

    /// `displays` displays and one window per entry of `titles`; `App0` owns the first card, so a
    /// payload in `titles[0]` reaches the card body, the card caption and the footer.
    private func model(titles: [String?], displays: Int = 1) -> WallModel {
        WallModel(
            displays: (0..<max(1, displays)).map {
                WallDisplay(name: "Display\($0)", width: 1512, height: 982, main: $0 == 0)
            },
            windows: titles.enumerated().map { window($0.offset, title: $0.element) }
        )
    }

    private func makeLayout(_ model: WallModel, cols: Int, rows: Int, per: Int = 3) -> WallLayout {
        var state = WallState()
        state.per = per
        return state.layout(cols: cols, rows: rows, displays: model.displays.count,
                            windows: model.windows.count)
    }

    /// A fresh canvas every time: `prev == nil`, so `draw` is a full repaint and the bytes are the
    /// whole wall rather than a diff.
    private func draw(_ model: WallModel, _ layout: WallLayout, cols: Int, rows: Int,
                      focus: WallState.Focus? = nil,
                      paints: WallSlotPaints = WallSlotPaints()) -> [UInt8] {
        WallCanvas().draw(cols: cols, rows: rows, model: model, layout: layout, focus: focus,
                          cellW: cellW, cellH: cellH, paints: paints)
    }

    // MARK: - byte-level helpers

    /// One positioned write: `ESC[<row>;<col>H` and the characters sent before the next cursor
    /// move. An SGR inside the run is not part of the text - it moves no cursor.
    private struct Write {
        var row: Int
        var col: Int
        var text: String = ""
        /// The cells the terminal advances for this run: every emitted character by
        /// `DisplayWidth`'s table. A wide glyph is one character and counts two; the grid's
        /// continuation cell is never sent, so it is never counted.
        var advance: Int { text.reduce(0) { $0 + DisplayWidth.of($1) } }
    }

    private struct ByteParse {
        var writes: [Write] = []
        /// Every escape sequence, verbatim, in the order it appears.
        var escapes: [String] = []
        /// Escapes that are neither a cursor move (`…H`) nor an SGR (`…m`), and any character sent
        /// with no cursor move in front of it.
        var stray: [String] = []
    }

    private func scalarValue(_ ch: Character) -> UInt32? {
        let scalars = ch.unicodeScalars
        return scalars.count == 1 ? scalars.first!.value : nil
    }

    /// Walk the byte stream and cut it at every cursor move. Whatever a title smuggled in is still
    /// in there, which is the point: this parser is how the tests see it.
    private func parse(_ bytes: [UInt8]) -> ByteParse {
        let chars = Array(String(decoding: bytes, as: UTF8.self))
        var out = ByteParse()
        var current: Int? = nil
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            guard ch == "\u{1B}" else {
                if let c = current {
                    out.writes[c].text.append(ch)
                } else {
                    out.stray.append("\(ch.debugDescription) written with no cursor move")
                }
                i += 1
                continue
            }
            let start = i
            var k = i + 1
            if k < chars.count, chars[k] == "[" {
                k += 1
                while k < chars.count, let v = scalarValue(chars[k]), (0x30...0x3F).contains(v) {
                    k += 1
                }
                while k < chars.count, let v = scalarValue(chars[k]), (0x20...0x2F).contains(v) {
                    k += 1
                }
            }
            let final = k < chars.count ? chars[k] : nil
            let end = min(k + 1, chars.count)
            let seq = String(chars[start..<end])
            out.escapes.append(seq)
            if final == "H" {
                let body = String(chars[(start + 2)..<k])
                let parts = body.split(separator: ";")
                if parts.count == 2, let r = Int(parts[0]), let c = Int(parts[1]) {
                    out.writes.append(Write(row: r, col: c))
                    current = out.writes.count - 1
                } else {
                    out.stray.append(seq)
                }
            } else if final == "m" {
                // An SGR: style only, the run continues.
            } else {
                out.stray.append(seq)
            }
            i = end
        }
        return out
    }

    // MARK: - row-level helpers

    /// A C0 control scalar is not a glyph: it is a command the terminal obeys.
    private func controlScalar(in row: String) -> UnicodeScalar? {
        row.unicodeScalars.first { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// The first ESC in `row` that does not begin a complete CSI sequence ending on a final byte
    /// inside the row - i.e. a truncation that landed mid-escape.
    private func danglingEscape(in row: String) -> String? {
        let chars = Array(row)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\u{1B}" else { i += 1; continue }
            var k = i + 1
            guard k < chars.count, chars[k] == "[" else {
                return "ESC with no CSI after it: \(String(chars[i...]).debugDescription)"
            }
            k += 1
            while k < chars.count, let v = scalarValue(chars[k]), (0x30...0x3F).contains(v) { k += 1 }
            while k < chars.count, let v = scalarValue(chars[k]), (0x20...0x2F).contains(v) { k += 1 }
            guard k < chars.count, let v = scalarValue(chars[k]), (0x40...0x7E).contains(v) else {
                return "a row ends inside an escape: \(String(chars[i...]).debugDescription)"
            }
            i = k + 1
        }
        return nil
    }

    /// Collects violations so one test reports one readable list instead of forty assertion
    /// failures. Capped: the first few are the diagnosis, the count is the size of the bug.
    private final class Violations {
        private var lines: [String] = []
        private var dropped = 0
        private let limit: Int
        /// Everything ever added, kept separately from the capped list so a test can say *which*
        /// payloads are broken even when the list itself is truncated.
        private(set) var total = 0
        init(limit: Int = 12) { self.limit = limit }
        func add(_ line: String) {
            total += 1
            if lines.count < limit { lines.append(line) } else { dropped += 1 }
        }
        var isEmpty: Bool { lines.isEmpty }
        var summary: String {
            (lines + (dropped == 0 ? [] : ["… and \(dropped) more"])).joined(separator: "\n")
        }
    }

    /// Every escape in `bytes` must be a cursor move (`ESC[<r>;<c>H`) or an SGR (`ESC[…m`), and
    /// every run must stay inside the pane, off `(rows, cols)`, and never advance past the last
    /// column of the final row.
    private func writeViolations(_ bytes: [UInt8], cols: Int, rows: Int,
                                 into bad: Violations, label: String) {
        let p = parse(bytes)
        for escape in p.stray {
            bad.add("\(label): stray escape \(escape.debugDescription)")
        }
        for w in p.writes {
            if w.row < 1 || w.row > rows || w.col < 1 || w.col > cols {
                bad.add("\(label): write positioned at (\(w.row),\(w.col)) outside a \(cols)x\(rows) pane")
                continue
            }
            guard w.row == rows else { continue }
            let last = w.col + w.advance - 1
            if w.col == cols {
                bad.add("\(label): row \(rows) write starts at col \(cols) (the final cell) - "
                        + "advance \(w.advance), text \(w.text.debugDescription)")
            } else if last > cols - 1 {
                bad.add("\(label): row \(rows) write col \(w.col)…\(last) advances past \(cols - 1) "
                        + "(advance \(w.advance), text \(w.text.debugDescription))")
            }
        }
    }

    // MARK: - (a) a newline in a title is a newline in the pane

    func testTitleWithNewlineDoesNotEmitNewline() {
        let title = "a\nbbbb"
        let m = model(titles: [title, "two", "three", "four", "five"])
        let l = makeLayout(m, cols: cols, rows: rows)
        let bytes = draw(m, l, cols: cols, rows: rows)

        let newlines = bytes.filter { $0 == 0x0A }.count
        var context = "no 0x0A at all"
        if let idx = bytes.firstIndex(of: 0x0A) {
            let lo = max(0, idx - 48)
            let hi = min(bytes.count, idx + 24)
            let window = String(decoding: bytes[lo..<hi], as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
                .replacingOccurrences(of: "\n", with: "<LF>")
            context = "first 0x0A at byte \(idx): …\(window)…"
        }
        XCTAssertEqual(newlines, 0,
                       "WallCanvas invariant 1 says a draw never emits \\n (a newline on the last "
                       + "row scrolls the grid and puts every kitty placement one row off). This "
                       + "draw emitted \(newlines) 0x0A byte(s) from a window title; \(context)")

        // The footer prints the picked window's title too - and the footer *is* the last pane row,
        // so there a newline is not a stray byte but the scroll invariant 1 is about.
        let picked = draw(m, l, cols: cols, rows: rows, focus: .window(0))
        let p = parse(picked)
        let onFinalRow = p.writes.filter { $0.row == rows && $0.text.contains("\n") }
        let footerNewlines = picked.filter { $0 == 0x0A }.count
        XCTAssertEqual(onFinalRow.count, 0,
                       "with a window picked the footer draws its title on row \(rows), the last "
                       + "row: \(footerNewlines) 0x0A byte(s), \(onFinalRow.count) run(s) on the "
                       + "last row at \(onFinalRow.map { "col \($0.col)…\($0.col + $0.advance - 1)" })")
    }

    // MARK: - (b) an escape in a title is an escape in the pane

    func testTitleWithEscapeDoesNotInjectControl() {
        let title = "title\u{1B}[2Jcleared"
        let m = model(titles: [title, "two", "three", "four", "five"])
        let l = makeLayout(m, cols: cols, rows: rows)
        let bytes = draw(m, l, cols: cols, rows: rows)
        let p = parse(bytes)

        let escapes = bytes.filter { $0 == 0x1B }.count
        let injected = p.escapes.filter { $0 == "\u{1B}[2J" }
        let notAPositionedWrite = p.escapes.filter {
            !($0.hasPrefix("\u{1B}[") && ($0.hasSuffix("H") || $0.hasSuffix("m")))
        }
        var produced = "none"
        if let first = notAPositionedWrite.first {
            produced = first.debugDescription
        }
        XCTAssertEqual(injected.count, 0,
                       "the renderer only ever sends ESC[<r>;<c>H and ESC[<sgr>m, so a title must "
                       + "not be able to spell ESC[2J (clear screen). Found \(injected.count) of "
                       + "them in \(escapes) ESC byte(s); first bad sequence \(produced)")
        XCTAssertEqual(notAPositionedWrite.count, 0,
                       "every ESC must be a cursor move or an SGR; \(escapes) ESC byte(s) "
                       + "produced \(notAPositionedWrite.count) that are neither: "
                       + "\(notAPositionedWrite.prefix(4).map(\.debugDescription))")
        XCTAssertTrue(p.stray.isEmpty,
                      "a stray escape breaks the parse of every write after it: "
                      + "\(p.stray.prefix(4).map(\.debugDescription))")
    }

    // MARK: - (c) every row of `lines` is exactly `cols` cells, for any title

    func testRowsAreExactlyColsCellsForHostileTitles() {
        let payloads: [(name: String, title: String?)] = [
            ("cjk-60", String(repeating: "访达", count: 30)),
            ("emoji-zwj-family", String(repeating: "👨‍👩‍👧‍👦", count: 40)),
            ("esc-lf-mix", "\u{1B}[2J\u{0A}wiped\u{1B}]0;evil\u{07}"),
            ("lone-combining", "\u{0301}"),
            ("rtl-hebrew", "שלום עולם — בדיקה של כותרת חלון ארוכה"),
            ("empty", ""),
            ("nil", nil),
            ("ascii-300", String(repeating: "abcdefghij", count: 30)),
        ]
        let bad = Violations()
        var tally: [String] = []
        for payload in payloads {
            let before = bad.total
            let m = model(titles: Array(repeating: payload.title, count: 5))
            let l = makeLayout(m, cols: cols, rows: rows)
            // Both the landing frame and the "picked a window" frame: the footer prints the title
            // too, on a different row and with a different truncation budget.
            for (name, focus) in [("landing", WallState.Focus?.none),
                                  ("picked", WallState.Focus?.some(.window(0)))] {
                let lines = WallCanvas().lines(cols: cols, rows: rows, model: m, layout: l,
                                               focus: focus, cellW: cellW, cellH: cellH)
                XCTAssertEqual(lines.count, rows)
                for (i, row) in lines.enumerated() {
                    let tag = "\(payload.name)/\(name) row \(i + 1)"
                    let width = DisplayWidth.of(row)
                    if width != cols {
                        bad.add("\(tag): \(width) cells, wanted \(cols): \(row.debugDescription)")
                    }
                    if let scalar = controlScalar(in: row) {
                        bad.add("\(tag): raw U+"
                                + String(format: "%04X", scalar.value)
                                + " in the grid: \(row.debugDescription)")
                    }
                    if let dangling = danglingEscape(in: row) {
                        bad.add("\(tag): \(dangling)")
                    }
                }
                // The bytes must agree with `lines`: a control scalar in the grid is one in the
                // stream, which is what makes (a) and (b) possible at all.
                let bytes = draw(m, l, cols: cols, rows: rows, focus: focus)
                writeViolations(bytes, cols: cols, rows: rows, into: bad, label: "\(payload.name)/\(name)")
            }
            tally.append("\(payload.name)=\(bad.total - before)")
        }
        XCTAssertTrue(bad.isEmpty,
                      "every row of `lines` must be exactly \(cols) cells of printable glyphs, for "
                      + "any window title. Violations per payload: \(tally.joined(separator: ", "))"
                      + "\n\(bad.summary)")
    }

    // MARK: - (d) a mask says why, inside its own box

    func testMasksRenderTheReasonInsideTheBox() {
        let m = model(titles: ["one", "two", "three", "four", "five"])
        let l = makeLayout(m, cols: cols, rows: rows)

        // slot 0 is the stage, slots 1…3 are the three cards of this page (WallSlotPaints.mark).
        let closed: PanelCaptureError = .windowGone
        let denied: PanelCaptureError = .denied
        let noPixels: PanelCaptureError = .noPixelBuffer
        let noStream: PanelCaptureError = .failed("SCStreamError -3805")
        let reasons: [(slot: Int, label: String)] = [
            (0, closed.maskLabel), (1, denied.maskLabel),
            (2, noPixels.maskLabel), (3, noStream.maskLabel),
        ]
        var paints = WallSlotPaints()
        for r in reasons {
            paints.mark(slot: r.slot, .mask)
            paints.maskReasons[r.slot] = r.label
        }
        // The label constants are what the reader sees; pin them here so a silent rename shows up.
        XCTAssertEqual(reasons.map(\.label), ["closed", "denied", "no pixels", "no stream"])

        let lines = WallCanvas().lines(cols: cols, rows: rows, model: m, layout: l, focus: nil,
                                       cellW: cellW, cellH: cellH, paints: paints)
        let bad = Violations()
        for r in reasons {
            let rect: CellRect
            if r.slot == 0 {
                rect = l.stage
            } else {
                guard l.cards.indices.contains(r.slot - 1) else {
                    bad.add("slot \(r.slot): no card rect at this size")
                    continue
                }
                rect = l.cards[r.slot - 1]
            }
            let middle = rect.row + (rect.rows - 1) / 2
            guard lines.indices.contains(middle - 1) else {
                bad.add("slot \(r.slot): middle row \(middle) is outside the pane")
                continue
            }
            let row = lines[middle - 1]
            guard let range = row.range(of: r.label) else {
                bad.add("slot \(r.slot): \(r.label.debugDescription) is not on the box's middle "
                        + "row \(middle) (\(rect.col)…\(rect.maxCol)): \(row.debugDescription)")
                continue
            }
            let start = 1 + DisplayWidth.of(String(row[row.startIndex..<range.lowerBound]))
            let end = start + DisplayWidth.of(r.label) - 1
            if start < rect.col + 1 || end > rect.maxCol - 1 {
                bad.add("slot \(r.slot): \(r.label.debugDescription) sits at col \(start)…\(end), "
                        + "outside the box interior \(rect.col + 1)…\(rect.maxCol - 1) "
                        + "(box \(rect.col)…\(rect.maxCol), row \(middle))")
            }
        }
        // Nothing may touch the final cell of the final row, mask or not.
        let bytes = draw(m, l, cols: cols, rows: rows, paints: paints)
        writeViolations(bytes, cols: cols, rows: rows, into: bad, label: "masks")
        XCTAssertTrue(bad.isEmpty, "every mask must name its reason inside its own box:\n\(bad.summary)")
    }

    // MARK: - (e) the final-cell rule at every size

    func testFinalCellRuleAtEverySize() {
        // Width-hostile, plus the raw LF class, and deliberately no ESC: this test measures the
        // final-cell rule, and an injected escape is (b)'s bug - it would break the parse of every
        // run after it and turn one finding into two.
        let hostile: [String?] = [
            String(repeating: "访达", count: 30),
            String(repeating: "👨‍👩‍👧‍👦", count: 40),
            "\u{0A}wiped\u{0A}",
            "\u{0301}",
            "שלום עולם — בדיקה",
            nil,
            String(repeating: "abcdefghij", count: 30),
        ]
        let bad = Violations()
        var panes = 0
        for paneRows in 5...25 {
            for paneCols in 10...60 {
                panes += 1
                let m = model(titles: hostile, displays: 3)
                let l = makeLayout(m, cols: paneCols, rows: paneRows)
                let bytes = draw(m, l, cols: paneCols, rows: paneRows)
                writeViolations(bytes, cols: paneCols, rows: paneRows, into: bad,
                                label: "pane \(paneCols)x\(paneRows)")
            }
        }
        XCTAssertGreaterThan(panes, 0)
        XCTAssertTrue(bad.isEmpty,
                      "the final cell (rows, cols) is never ours to write: writing it arms "
                      + "pending-wrap and the next byte scrolls the grid. Over \(panes) panes "
                      + "(rows 5…25 x cols 10…60):\n\(bad.summary)")
    }

    /// The smallest pane that reproduces a violation, when the sweep finds one: one window whose
    /// title is the payload, one row per band, nothing else. Kept beside the sweep so a failure
    /// names a size a reader can reproduce by hand.
    func testFinalCellRuleMinimalCase() {
        let payload = String(repeating: "访达", count: 30)
        let bad = Violations()
        for paneRows in 5...25 {
            for paneCols in 10...60 {
                let m = model(titles: [payload, nil, payload], displays: 2)
                let l = makeLayout(m, cols: paneCols, rows: paneRows, per: 3)
                let bytes = draw(m, l, cols: paneCols, rows: paneRows)
                writeViolations(bytes, cols: paneCols, rows: paneRows, into: bad,
                                label: "minimal \(paneCols)x\(paneRows)")
                if !bad.isEmpty { break }
            }
            if !bad.isEmpty { break }
        }
        XCTAssertTrue(bad.isEmpty, "minimal case:\n\(bad.summary)")
    }
}
