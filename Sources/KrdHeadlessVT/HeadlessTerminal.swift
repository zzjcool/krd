// A terminal you can ask about *cells*, for tests only (issue #218).
//
// The shipping `krd` does not link this: the target is declared in `Package.swift` only when
// `KRD_VT_XCFRAMEWORK` points at a `ghostty-vt.xcframework`, and only the `krdTests` target depends
// on it. See `docs/TESTING.md` §13 for the switch and for what a developer sees without it.
//
// Why this exists at all: every UI test in this tree is either pure (a widget table, a layout) or a
// pty process test that has to *find* things in a 130 KB byte stream. Bytes can be searched for
// `\033[4m`, but they cannot be asked "which cells end up underlined, and is that the same cell that
// carries the faint dim style". A VT can: `WallCanvas` writes into it and the test reads back cells.
//
// The wrapper is deliberately two screens long: create a terminal, write bytes, read one cell (text,
// foreground, attributes). Anything more (render state, dirty rects, kitty graphics) is a product
// concern and not what a rendering test needs.
//
// **Settling.** libghostty-vt applies a write synchronously — including inside the `?2026h`/`?2026l`
// synchronized-output blocks krd uses, which are a hint to the renderer and not a buffer. So there is
// nothing to wait for and this file has no sleep: `write` returns only after every byte in the buffer
// has been consumed, and a caller that wants a "did the frame land" proof reads a cell. The tests
// still state that as an assertion (`HeadlessRenderTests.testTheFrameLandsAndTheSecondDrawIsFree`)
// rather than trusting it.

import Foundation
import GhosttyVt

/// One 24-bit colour, in the same shape as `krdcore.RGB` but without the dependency: this target is
/// a test-only shim over C and pulling the product's palette in would make the two hard to tell
/// apart in a stack trace.
public struct HeadlessColor: Equatable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The SGR/hex form the rest of the tree writes colours in (`0xRRGGBB`).
    public var hex: UInt32 { UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue) }
}

/// The attributes a cell carries, as the terminal's final state for that cell — i.e. what the byte
/// stream *settled to*, not what the last escape in it said.
public struct HeadlessAttributes: Equatable {
    public var bold = false
    public var faint = false
    public var italic = false
    public var inverse = false
    /// `SGR 4` in any of its forms (single, curly, dotted, …): the focus ring's bit.
    public var underline = false
    public var strikethrough = false
}

/// One grid cell.
///
/// `text` is empty for a cell nothing was written to and for the tail of a wide glyph; `wide` marks the head of a
/// two-cell glyph, so a test can check that the wall's glyph widths agree with the terminal's own
/// table (they do by construction — `WidthTable.swift` was generated from this library).
public struct HeadlessCell: Equatable {
    public var text: String
    /// `nil` means "no colour of its own": the cell paints in the terminal's default foreground.
    public var foreground: HeadlessColor?
    public var attributes = HeadlessAttributes()
    public var wide = false
    /// The second half of a wide glyph: it occupies a cell, but writing its text on its own is wrong.
    public var continuation = false
}

/// What the terminal thinks the cursor is doing, for the write-invariant assertions (a frame must not
/// leave the cursor in the armed-pending-wrap state, and must not have scrolled).
public struct HeadlessCursor: Equatable {
    public var col: Int
    public var row: Int
    public var pendingWrap: Bool
    public var visible: Bool
}

public struct HeadlessTerminalError: Error, CustomStringConvertible {
    public var call: String
    public var code: Int32

    public var description: String { "\(call) failed: \(Self.name(code)) (\(code))" }

    static func name(_ code: Int32) -> String {
        switch code {
        case GHOSTTY_SUCCESS.rawValue: return "GHOSTTY_SUCCESS"
        case GHOSTTY_OUT_OF_MEMORY.rawValue: return "GHOSTTY_OUT_OF_MEMORY"
        case GHOSTTY_INVALID_VALUE.rawValue: return "GHOSTTY_INVALID_VALUE"
        case GHOSTTY_OUT_OF_SPACE.rawValue: return "GHOSTTY_OUT_OF_SPACE"
        case GHOSTTY_NO_VALUE.rawValue: return "GHOSTTY_NO_VALUE"
        case GHOSTTY_IO_ERROR.rawValue: return "GHOSTTY_IO_ERROR"
        case GHOSTTY_LIMIT_EXCEEDED.rawValue: return "GHOSTTY_LIMIT_EXCEEDED"
        case GHOSTTY_REJECTED.rawValue: return "GHOSTTY_REJECTED"
        default: return "unknown"
        }
    }
}

/// A headless terminal: write the bytes `WallCanvas` produced, then read the cells back.
///
/// One instance per test that needs one; it is not thread-safe (neither is the C library).
public final class HeadlessTerminal {
    public let cols: Int
    public let rows: Int

    private let handle: GhosttyTerminal

    /// `cols`/`rows` are the *pane* the bytes were rendered for: `WallCanvas.draw(cols:rows:…)` for a
    /// 137x44 pane has to be fed to a 137x44 terminal, or the cursor moves land on different cells.
    public init(cols: Int, rows: Int) throws {
        precondition(cols > 0 && rows > 0, "a terminal needs a positive size")
        var handle: GhosttyTerminal?
        let result = ghostty_terminal_new(nil, &handle, UInt16(cols), UInt16(rows))
        guard result == GHOSTTY_SUCCESS, let handle else {
            throw HeadlessTerminalError(call: "ghostty_terminal_new(\(cols)x\(rows))",
                                        code: result.rawValue)
        }
        self.handle = handle
        self.cols = cols
        self.rows = rows
    }

    deinit { ghostty_terminal_free(handle) }

    /// Feed a whole frame (or one escape at a time — the terminal is incremental).
    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buffer in
            ghostty_terminal_vt_write(handle, buffer.baseAddress, buffer.count)
        }
    }

    public func write(_ text: String) { write(Array(text.utf8)) }

    // MARK: reading

    /// One cell, 0-based like the C API. Out-of-range reads are a mistake in the test, not a state to
    /// paper over: they trap with the coordinate that asked.
    public func cell(col: Int, row: Int) -> HeadlessCell {
        precondition(col >= 0 && col < cols && row >= 0 && row < rows,
                     "cell(\(col), \(row)) is outside \(cols)x\(rows)")
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate.x = UInt16(col)
        point.value.coordinate.y = UInt32(row)
        let resolved = ghostty_terminal_grid_ref(handle, point, &ref)
        precondition(resolved == GHOSTTY_SUCCESS, "ghostty_terminal_grid_ref(\(col), \(row))")

        var cell = GhosttyCell(0)
        precondition(ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS, "ghostty_grid_ref_cell")

        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        precondition(ghostty_grid_ref_style(&ref, &style) == GHOSTTY_SUCCESS, "ghostty_grid_ref_style")

        var out = HeadlessCell(text: "")
        var codepoint: UInt32 = 0
        // `ghostty_cell_get` answers SUCCESS with codepoint 0 for an empty cell ("0 if empty or
        // bg-color-only", screen.h), and U+0000 *is* a valid `Unicode.Scalar` — so without the
        // `codepoint != 0` guard, a cell nothing was written to reads back as a NUL character
        // instead of as no text, which is a lie every blank-cell assertion would believe.
        if ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint) == GHOSTTY_SUCCESS,
           codepoint != 0,
           let scalar = Unicode.Scalar(codepoint) {
            out.text = String(Character(scalar))
        }
        var wide = GHOSTTY_CELL_WIDE_NARROW
        if ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS {
            out.wide = wide == GHOSTTY_CELL_WIDE_WIDE
            out.continuation = wide == GHOSTTY_CELL_WIDE_SPACER_TAIL
        }
        if style.fg_color.tag == GHOSTTY_STYLE_COLOR_RGB {
            let rgb = style.fg_color.value.rgb
            out.foreground = HeadlessColor(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
        out.attributes.bold = style.bold
        out.attributes.faint = style.faint
        out.attributes.italic = style.italic
        out.attributes.inverse = style.inverse
        out.attributes.strikethrough = style.strikethrough
        out.attributes.underline = style.underline != GHOSTTY_SGR_UNDERLINE_NONE.rawValue
        return out
    }

    /// A whole row, left to right.
    public func row(_ row: Int) -> [HeadlessCell] {
        (0..<cols).map { cell(col: $0, row: row) }
    }

    /// The text of a row as the terminal would draw it: wide glyphs once, their tails skipped, blanks
    /// as spaces. Trailing blanks are kept — a caption's *width* is part of what a test asserts.
    public func line(_ row: Int) -> String {
        var out = ""
        for cell in self.row(row) where !cell.continuation {
            out += cell.text.isEmpty ? " " : cell.text
        }
        return out
    }

    public var cursor: HeadlessCursor {
        var col: UInt16 = 0
        var row: UInt16 = 0
        var pending = false
        var visible = false
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_X, &col)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &row)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &pending)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible)
        return HeadlessCursor(col: Int(col), row: Int(row), pendingWrap: pending, visible: visible)
    }

    /// Rows that scrolled off the top. A wall frame must leave this at 0 (the write invariants in
    /// `WallCanvas` exist so nothing ever scrolls), so a test asserts it rather than reading it.
    public var scrollbackRows: Int {
        var value = 0                     // `size_t *` in C, i.e. `Int` here
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &value)
        return value
    }
}
