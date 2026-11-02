import Foundation

/// One frame of an icon: the pixels, and the shape the terminal needs to draw them.
///
/// Pixels are held as the caller rasterised them (row-major, `format`'s channels) and not as a
/// compressed payload, because the cache *compares* them: the key of a picture is its content
/// (design §4.3's "an icon is transmitted once and afterwards costs only a placement", issue #217),
/// so two callers that draw the same glyph land on the same entry without having to agree on a name
/// for it. A name would be a second thing to keep right, and the day it went stale the terminal
/// would be shown the wrong picture under the right id.
public struct IconImage: Equatable {
    public var width: Int
    public var height: Int
    /// Row-major, `format`'s channels, `width * height` pixels.
    public var pixels: [UInt8]
    public var format: PixelFormat

    public init(width: Int, height: Int, pixels: [UInt8], format: PixelFormat = .rgb) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.format = format
    }

    /// The byte count `pixels` has to be for this size. The way a caller gets this wrong is leaving a
    /// channel out or reusing last frame's buffer, and neither is refused by the terminal: it reads
    /// the buffer at its own stride and draws a sheared picture. So a frame that does not add up is
    /// not transmitted (see `IconCache.draw`).
    var expectedByteCount: Int { width * height * format.bytesPerPixel }

    /// A frame the terminal could draw: a positive size and exactly the bytes that size needs.
    var isDrawable: Bool { width > 0 && height > 0 && pixels.count == expectedByteCount }
}

/// The pictures the terminal already holds, keyed by their content (issue #217, design §4.3).
///
/// The problem this exists for: the loading card re-rasterised a 36×36 dot picture and re-sent it as
/// pixels every 110 ms (issue #217's "what is on main today"), and the chrome would pay the same bill
/// for every glyph it wants to show, every frame. A picture that has not changed is not data: it is a
/// *placement* of an image the terminal already holds — 30-odd bytes instead of kilobytes — so the
/// cache's whole job is to answer "has this terminal seen this picture (on this palette) yet?" and to
/// return exactly the escapes that answer implies. The second draw of a key carries no image data at
/// all, and that is a property of the bytes (`Emit.payloadBytes == 0`), not of a hit counter.
///
/// Keyed by content and palette, never by name:
/// - Content, because the two callers have no names in common — the loader's frames are rasterised in
///   `LoadingView`, the chrome's icons come out of the theme layer — and a shared name is a shared
///   bug when the pictures behind it differ.
/// - Palette, because the same glyph on a light and a dark terminal is two different pictures: their
///   colours are the *theme layer's* (#213), so the bytes differ and only the shape is shared.
///
/// Not thread-safe, deliberately: it is a book of a few entries with no clock in it, and both call
/// sites (the loading card, the chrome) draw on the queue that owns the writer. A lock here would cost
/// more than the cache saves and would hide the real bug — a second writer.
public final class IconCache {
    /// A picture: one frame for a still image, more for an animation the terminal plays itself.
    ///
    /// `gapMs` is the one field the key does *not* cover (D7 keys on the frames): a caller that
    /// re-draws the same pixels with a different gap gets the gap the terminal was first told, because
    /// a running animation's timing is not something a placement can change. Nothing needs it today —
    /// the loader's gap is a constant of the blink curve — and a second one would be a second key.
    public struct Graphic: Equatable {
        public var frames: [IconImage]
        /// `z=` on frames 1…, and on the `a=a` that starts the loop; `0` = a still picture.
        public var gapMs: Int

        public init(frames: [IconImage], gapMs: Int = 0) {
            self.frames = frames
            self.gapMs = gapMs
        }

        /// The terminal has to be told to play it: more than one frame *and* a positive gap. A single
        /// frame with a gap is a still that would repeat itself, and the two `a=a` that would ask for
        /// that are bytes spent on nothing.
        var isAnimation: Bool { gapMs > 0 && frames.count > 1 }
    }

    /// How the image is put on the grid, and therefore which escapes carry the geometry.
    public enum Placement: Equatable {
        /// `C=1,c,r`: a pixel-sized placement on the card's cell box. The terminal scales the picture
        /// into the box, which is what a card wants: it knows its cells, not its terminal's DPI.
        case pixels(cols: Int, rows: Int)
        /// `U=1` plus the invisible `U+10EEEE` grid, the wall's transport (design §6.9).
        ///
        /// The origin is the caller's, in 1-based pane cells, because a `U=1` grid *is* text: a
        /// placeholder cell belongs to a row of the screen, not to the picture, so the grid has to be written
        /// where the picture goes. The chrome's inline icons are the callers that will want an origin
        /// other than the pane's first cell (the loading card does not use this transport at all —
        /// see `.pixels`).
        case cells(_ rect: CellRect, paneCols: Int, paneRows: Int)
    }

    /// What a picture is, for the book: its content and the palette it was drawn for.
    public struct Key: Hashable {
        public var content: UInt64
        public var palette: UInt64
    }

    /// What the caller writes, and what it may claim it cost.
    public struct Emit: Equatable {
        /// Exactly what goes to the writer: ASCII escapes plus, for a `.cells` placement, the
        /// `U+10EEEE` grid. No `?2026` block — the caller owns the one block around its whole card
        /// (D3), and a nested pair would end that block early.
        public var bytes: String
        public var id: Int
        public var key: Key
        /// Did `bytes` carry image data? True on the first draw of a key, false on every reuse.
        public var transmitted: Bool
        /// Base64 characters of image data in `bytes`; `0` on reuse. Base64 characters and not the
        /// whole write, because this is the number the byte budget is judged on (issue #217's
        /// "< 4 KB/s") and a placement's own escape is not a payload — a caller that pinned the whole
        /// write would fail the day the placement grows a field.
        public var payloadBytes: Int
    }

    /// The book's entry for one key: the id the terminal knows the picture by, and whether this
    /// process has sent it.
    private struct Book {
        var id: Int
        var sent: Bool
    }

    /// The next id to hand out, from `firstID` upwards. 9000 is above every other image id krd uses
    /// in one session: the mirror's tiles are `100 + index`, the wall's panels `5000 + slot`, the
    /// probes 31 and 32 (D6). A collision does not fail — one picture silently replaces the other's
    /// image, which is the hardest kind of bug to see.
    private var nextID: Int
    private let quiet: Int
    private let level: Int
    private var books: [Key: Book] = [:]

    /// `quiet` and `level` are the writer's, by default: an APC the cache emits that answered a
    /// terminal it was not asked about would be the one thing on this path that is not silent.
    public init(firstID: Int = 9000, quiet: Int = 2, level: Int = 5) {
        self.nextID = firstID
        self.quiet = quiet
        self.level = level
    }

    // MARK: - keys

    /// The palette's identity: FNV-1a over the terminal's own two colours, `0` for `nil`.
    ///
    /// The foreground and the background are the whole palette in the sense that matters: every
    /// surface, border and the accent are interpolations of that pair (#213), so two palettes with the
    /// same two colours derive the same eight and no picture can differ between them.
    ///
    /// `nil` is the hard-coded table — the panel a terminal never answered `OSC 10`/`OSC 11` gets —
    /// and `0` is its key. A real palette would have to hash to exactly zero to be mistaken for it,
    /// which is not a case worth a branch.
    public static func paletteKey(_ palette: Palette?) -> UInt64 {
        guard let palette else { return 0 }
        var fnv = FNV1a()
        for colour in [palette.foreground, palette.background] {
            fnv.feed(colour.r)
            fnv.feed(colour.g)
            fnv.feed(colour.b)
        }
        return fnv.value
    }

    /// The pictures' identity: FNV-1a over every frame in order — width, height, the format's channel
    /// count, then the pixel bytes (D7).
    ///
    /// Order-dependent on purpose: a frame swapped with its neighbour is a different animation, and
    /// two frames of the same picture would otherwise be indistinguishable from one.
    ///
    /// FNV-1a rather than `Hasher` because the number is part of the contract and is printed in
    /// reports: `Hasher` is seeded per process, so the same picture would have a different key in the
    /// next run and a key quoted in a bug report would mean nothing.
    public static func contentHash(frames: [IconImage]) -> UInt64 {
        var fnv = FNV1a()
        for frame in frames {
            fnv.feed(le: frame.width)
            fnv.feed(le: frame.height)
            fnv.feed(UInt8(truncatingIfNeeded: frame.format.protocolChannels))
            fnv.feed(frame.pixels)
        }
        return fnv.value
    }

    // MARK: - drawing

    /// The escapes for this picture at this placement, transmitting only if the terminal has not been
    /// given these exact pixels on this exact palette.
    ///
    /// The first draw of a key: `a=t` for frame 0, `a=f` for each later frame (with `z=` for the gap),
    /// the two `a=a` that set the root frame's gap and start the loop forever (kitty: the base image
    /// carries no gap, so the animation only runs once the terminal is told to), then the placement.
    /// Every later draw: the placement, and nothing else.
    ///
    /// A graphic whose frames do not add up (see `IconImage.isDrawable`) or that zlib cannot compress
    /// draws nothing at all rather than a hole: a placement of an image the terminal never received is
    /// a blank rectangle on the grid, and a half-transmitted animation plays at the wrong speed.
    public func draw(_ graphic: Graphic, palette: UInt64, at placement: Placement) -> Emit {
        let key = Key(content: Self.contentHash(frames: graphic.frames), palette: palette)
        // An empty book entry would place an image no transmit ever sent: `allSatisfy` is true of no
        // frames, so the emptiness is its own guard rather than a hole in this one.
        guard !graphic.frames.isEmpty, graphic.frames.allSatisfy(\.isDrawable) else {
            return Emit(bytes: "", id: 0, key: key, transmitted: false, payloadBytes: 0)
        }
        var book = books[key] ?? Book(id: nextID, sent: false)
        if books[key] == nil {
            nextID += 1                  // the id belongs to this key from now on, sent or not
            books[key] = book
        }
        var bytes = ""
        var payloadBytes = 0
        if !book.sent {
            guard let sent = transmit(graphic, id: book.id) else {
                return Emit(bytes: "", id: book.id, key: key, transmitted: false, payloadBytes: 0)
            }
            bytes = sent.bytes
            payloadBytes = sent.payloadBytes
            book.sent = true
            books[key] = book
        }
        bytes += placementBytes(placement, id: book.id)
        return Emit(bytes: bytes, id: book.id, key: key, transmitted: payloadBytes > 0,
                    payloadBytes: payloadBytes)
    }

    /// Drop the book for this key, so the next draw transmits again.
    ///
    /// The caller has just `a=d`-deleted the image (the loader's `stop()`, D4): the terminal no longer
    /// holds it, and a placement of it would draw nothing. The id is kept — a forgotten picture is the
    /// same picture, and re-transmitting under the id it had makes the second card's bytes identical
    /// to the first's, which is the property that lets a test tell "forgot" from "transmitted once".
    public func forget(_ graphic: Graphic, palette: UInt64) {
        let key = Key(content: Self.contentHash(frames: graphic.frames), palette: palette)
        guard let book = books[key] else { return }
        books[key] = Book(id: book.id, sent: false)
    }

    // MARK: - the wire

    /// The transmit half: every frame, then the two `a=a`. `nil` when a frame will not compress —
    /// nothing of a picture is sent unless all of it can be.
    private func transmit(_ graphic: Graphic, id: Int) -> (bytes: String, payloadBytes: Int)? {
        var out = ""
        var payloadBytes = 0
        for (index, frame) in graphic.frames.enumerated() {
            guard let payload = zlibCompress(frame.pixels, level: level), !payload.isEmpty else {
                return nil
            }
            // Frame 0 is the transmit, `a=t`: the one frame that *is* the picture. An `a=f` there
            // would be a frame of an animation that nobody started.
            let action = index == 0 ? "t" : "f"
            // `z=` only where the protocol wants a delay: the base image carries none (kitty has the
            // gap set by `a=a` below), and a still has no gap at all.
            let gapMs = index > 0 && graphic.gapMs > 0 ? graphic.gapMs : nil
            let sent = transmitChunks(frame: frame, payload: payload, id: id, action: action,
                                      gapMs: gapMs)
            out += sent.bytes
            payloadBytes += sent.payloadBytes
        }
        if graphic.isAnimation {
            // The root frame's own gap, then "run normally, loop for ever" (`s=3,v=1`): without the
            // second APC the frames are transmitted and never played.
            out += GraphicsAPC.sequence("Gi=\(id),a=a,r=1,z=\(graphic.gapMs)")
            out += GraphicsAPC.sequence("Gi=\(id),a=a,s=3,v=1")
        }
        return (out, payloadBytes)
    }

    /// One frame's `a=t`/`a=f` APC, in 4096-character `m=` chunks — the shape
    /// `ScreenWriter.appendTransmit` writes, reproduced here rather than called because that function
    /// appends into the writer's own buffer and this one has to hand its bytes back. Two shapes for
    /// the same control list would be two protocols, and the loader's picture is bigger than one chunk
    /// (36×45×3 B is ~6.5 KB of base64), so the chunking is not a detail it can omit.
    private func transmitChunks(frame: IconImage, payload: [UInt8], id: Int, action: String,
                                gapMs: Int?) -> (bytes: String, payloadBytes: Int) {
        let chars = Array(Data(payload).base64EncodedString().utf8)
        let gap = gapMs.map { ",z=\($0)" } ?? ""
        let control = "Gf=\(frame.format.protocolChannels),s=\(frame.width),v=\(frame.height)"
            + ",a=\(action),o=z,q=\(quiet),i=\(id)\(gap)"
        var out = ""
        var i = 0
        var first = true
        while i < chars.count {
            let end = min(i + Self.chunkChars, chars.count)
            let more = end == chars.count ? 0 : 1
            let header = first ? "\(control),m=\(more);" : "Gm=\(more);"
            out += GraphicsAPC.sequence(header + String(decoding: chars[i..<end], as: UTF8.self))
            i = end
            first = false
        }
        return (out, chars.count)
    }

    /// The placement half: 30-odd bytes for a `.pixels` card, the grid for a `.cells` picture.
    ///
    /// A rectangle without cells draws nothing: `c=0` is a placement the terminal rejects, and a
    /// rejection is a write that bought nothing.
    private func placementBytes(_ placement: Placement, id: Int) -> String {
        switch placement {
        case let .pixels(cols, rows):
            guard cols > 0, rows > 0 else { return "" }
            return GraphicsAPC.sequence("Gi=\(id),p=\(id),a=p,q=\(quiet),C=1,c=\(cols),r=\(rows)")

        case let .cells(rect, paneCols, paneRows):
            guard rect.cols > 0, rect.rows > 0, rect.col > 0, rect.row > 0 else { return "" }
            // The virtual placement: the cell rectangle the terminal should fit the picture into.
            var out = GraphicsAPC.sequence("Gi=\(id),p=\(id),a=p,U=1,q=\(quiet)"
                                           + ",c=\(rect.cols),r=\(rect.rows)")
            // The cells themselves. The image id travels in the foreground colour and one diacritic
            // per row is enough: a cell inherits "the cell to its left, column + 1" (kitty
            // §Unicode placeholders), so `cols * rows` characters are the whole grid.
            let r = (id >> 16) & 0xFF, g = (id >> 8) & 0xFF, b = id & 0xFF
            let colour = "\u{1B}[38;2;\(r);\(g);\(b)m"
            for line in 0..<rect.rows {
                let paneRow = rect.row + line
                guard paneRow <= paneRows else { break }
                // Clipped so this never writes the final cell of the final pane row: a pending wrap
                // there scrolls the grid, and every placement on it follows one row up.
                var cells = rect.cols
                if paneRow == paneRows { cells = min(cells, paneCols - rect.col) }
                if cells <= 0 { break }
                out += "\u{1B}[\(paneRow);\(rect.col)H"
                out += colour
                for cell in 0..<cells {
                    out += "\u{10EEEE}"
                    if cell == 0, let mark = ScreenWriter.placeholderDiacritic(line) {
                        out += String(mark)
                    }
                }
                out += "\u{1B}[39m"
            }
            return out
        }
    }

    /// 4096 characters, the number `ScreenWriter.appendTransmit` uses: a multiplexer wraps a line at
    /// that size, and a stream with two chunk sizes would be re-wrapped inconsistently.
    private static let chunkChars = 4096
}

/// FNV-1a, 64-bit (D7): the hash a key is made of.
///
/// One 32-bit prime and one xor per byte, no table, no seed — the whole reason a key can be a number
/// in a document and in a test.
private struct FNV1a {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    private(set) var value = FNV1a.offsetBasis

    mutating func feed(_ byte: UInt8) { value = (value ^ UInt64(byte)) &* Self.prime }

    mutating func feed(_ bytes: [UInt8]) {
        for byte in bytes { feed(byte) }
    }

    /// A size as eight little-endian bytes: fixed width, so a width of 256 and a height of 1 cannot
    /// hash like a width of 1 and a height of 256.
    mutating func feed(le number: Int) {
        let bits = UInt64(bitPattern: Int64(number))
        for shift in stride(from: 0, to: 64, by: 8) {
            feed(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
    }
}
