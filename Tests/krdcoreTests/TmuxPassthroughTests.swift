import XCTest
@testable import krdcore

/// The tmux passthrough envelope (issue #107), pinned as a pure function.
///
/// Why this file exists: inside tmux the pane is a grid of missing-glyph boxes, because tmux consumes
/// an APC body itself (`input_state_apc_string`, `tmux/input.c`) instead of forwarding it — and the
/// virtual placement that carries krd's unicode-placeholder transport *is* an APC. The way through is
/// the DCS envelope every kitty-graphics program ships: `\ePtmux;` + the whole APC with every ESC
/// doubled + `\e\`.
///
/// Two things must never drift and both are checked below: the doubling (tmux un-doubles inside a DCS
/// and needs the *doubled* `ESC ESC \` to find the end of the payload), and the claim that wrapping is
/// nothing but an envelope — strip it and the stream is byte-for-byte the unwrapped one.
///
/// The end-to-end proof (a real tmux pane forwarding the picture) needs tmux installed and a terminal
/// behind it; this suite proves the bytes, which is the half a test process can see.
final class TmuxPassthroughTests: XCTestCase {
    private let esc = "\u{1B}"

    /// `GraphicsAPC.passthrough` is process-wide on purpose (the probe runs before any writer), so
    /// each case leaves it off again: a leak would envelope streams other cases expect raw.
    override func tearDown() {
        GraphicsAPC.passthrough = false
        super.tearDown()
    }

    /// The shapes krd actually puts on the wire, as complete APC sequences. Every emitter in
    /// `Render.swift` goes through `appendAPC`/`appendTransmitChunk`, and this is the corpus those
    /// helpers have to handle: transmit chunks (first and continuation), virtual placements with
    /// `U=1`, pixel placements with `C=1`, the delete pair, and the `emitVariant` diagnostic shape.
    private var corpus: [String] {
        let b64 = "iVBORw0KGgoAAAANSUhEUg=="   // stands in for a base64 payload; no ESC in base64
        return [
            // a=t transmit, first chunk of a compressed RGB tile (m=1: more chunks follow)
            "\(esc)_Gf=24,s=136,v=132,a=t,o=z,q=2,i=100,m=1;\(b64)\(esc)\\",
            // a=t continuation chunk
            "\(esc)_Gm=0;\(b64)\(esc)\\",
            // the wall's panel: virtual placement, unicode placeholders
            "\(esc)_Gi=5000,p=9000,a=p,U=1,q=2,c=3,r=2\(esc)\\",
            // the mirror's tile: virtual placement, the same transport
            "\(esc)_Gi=100,p=1000,a=p,U=1,q=2,c=8,r=4\(esc)\\",
            // a pixel-sized placement (--no-placeholders, and the pre-#6.9 shape)
            "\(esc)_Gi=100,p=1000,a=p,q=2,C=1,c=8,r=4\(esc)\\",
            // the delete: clear(), reapIfNeeded() and the deferred commit in endFrame
            "\(esc)_Ga=d,d=a\(esc)\\",
            // emitVariant's diagnostic transmit (a=T, geometry on the transmit itself)
            "\(esc)_Gf=32,s=8,v=4,a=T,o=z,q=2,i=7,C=1,c=4,r=2,m=0;\(b64)\(esc)\\",
        ]
    }

    // MARK: the envelope

    /// `\ePtmux;` … `\e\`, and nothing else outside it.
    func testTheWrappedFormIsTheEnvelopeAndOnlyTheEnvelope() {
        for sequence in corpus {
            let wrapped = TmuxPassthrough.wrap(sequence)
            XCTAssertTrue(wrapped.hasPrefix(TmuxPassthrough.prefix),
                          "wrapped does not start with the envelope: \(wrapped.prefix(24).debugDescription)")
            XCTAssertTrue(wrapped.hasSuffix(TmuxPassthrough.terminator))
            XCTAssertEqual(wrapped.utf8.count, sequence.utf8.count + TmuxPassthrough.prefix.utf8.count
                           + TmuxPassthrough.terminator.utf8.count + sequence.utf8.filter { $0 == 0x1B }.count,
                           "the envelope adds its prefix, its terminator and one byte per doubled ESC")
        }
    }

    /// Every interior ESC doubled, and no lone ESC left for tmux to mis-read as the end of the
    /// envelope.
    func testEveryInteriorEscapeIsDoubled() {
        for sequence in corpus {
            let wrapped = TmuxPassthrough.wrap(sequence)
            let body = Array(wrapped.utf8)[TmuxPassthrough.prefix.utf8.count..<(wrapped.utf8.count - TmuxPassthrough.terminator.utf8.count)]
            XCTAssertEqual(body.filter { $0 == 0x1B }.count, 2 * sequence.utf8.filter { $0 == 0x1B }.count,
                           "expected \(2 * sequence.utf8.filter { $0 == 0x1B }.count) ESCs, "
                           + "got \(body.filter { $0 == 0x1B }.count)")
            var i = body.startIndex
            while i < body.endIndex {
                if body[i] == 0x1B {
                    XCTAssertTrue(i + 1 < body.endIndex && body[i + 1] == 0x1B,
                                  "lone ESC in the payload at offset \(i) — tmux would end the envelope there")
                    i += 2
                } else {
                    i += 1
                }
            }
        }
    }

    /// `wrap(wrap⁻¹(x)) == x` and `wrap⁻¹(wrap(x)) == x`: the envelope is a bijection on the
    /// sequences krd emits, which is what makes it a transport change and not a format change.
    func testWrapAndUnwrapAreInverses() throws {
        for sequence in corpus {
            XCTAssertEqual(try XCTUnwrap(TmuxPassthrough.unwrap(TmuxPassthrough.wrap(sequence))), sequence)
            let wrapped = TmuxPassthrough.wrap(sequence)
            XCTAssertEqual(TmuxPassthrough.wrap(try XCTUnwrap(TmuxPassthrough.unwrap(wrapped))), wrapped)
        }
    }

    /// A half-doubled payload is refused rather than half-unwrapped: that is the state in which tmux
    /// and krd disagree about where the envelope ends, and guessing there would corrupt a picture.
    func testUnwrapRefusesAStrayEscapeAndAForeignString() {
        XCTAssertNil(TmuxPassthrough.unwrap("\(esc)Ptmux;\(esc)_Ga=d,d=a\(esc)\\"), "a lone ESC is not ours")
        XCTAssertNil(TmuxPassthrough.unwrap("\(esc)_Ga=d,d=a\(esc)\\"), "an unwrapped APC is not an envelope")
        XCTAssertNil(TmuxPassthrough.unwrap("hello"))
    }

    /// The emission fast path (`ScreenWriter.apcOpen`/`apcClose`, which appends the prefix and the
    /// doubled introducer/terminator around a body it knows is ESC-free) must equal the pure function,
    /// or the hot path and the tested path would be two different transforms.
    func testTheEmissionFastPathEqualsThePureFunction() {
        for sequence in corpus {
            let body = String(sequence.dropFirst("\(esc)_".count).dropLast("\(esc)\\".count))
            XCTAssertFalse(body.contains(esc), "a real APC body is ESC-free (control list + base64)")
            XCTAssertEqual(TmuxPassthrough.open + body + TmuxPassthrough.close,
                           TmuxPassthrough.wrap(sequence))
        }
    }

    // MARK: the flag (`--passthrough auto|on|off`, `KRD_PASSTHROUGH`)

    /// `auto` is the default and it is a `TERM` question: tmux names itself `tmux-*` and screen
    /// `screen-*`, and over ssh the *client's* TERM is what the far side sees. `$TMUX` is not
    /// consulted on purpose — it is absent when the tmux runs locally on the near side of the ssh.
    func testAutoWrapsOnlyForAMultiplexersTerm() {
        for term in ["tmux-256color", "tmux", "screen-256color", "screen.xterm-256color"] {
            XCTAssertTrue(TmuxPassthrough.resolve(flag: nil, env: ["TERM": term]).on, term)
        }
        for term in ["xterm-256color", "xterm-kitty", "alacritty", "wezterm", ""] {
            XCTAssertFalse(TmuxPassthrough.resolve(flag: nil, env: ["TERM": term]).on, term)
        }
        XCTAssertFalse(TmuxPassthrough.resolve(flag: nil, env: [:]).on, "no TERM at all is not a tmux")
    }

    /// The explicit answers: a server that forces `TERM=xterm` inside tmux is exactly why `on` exists,
    /// and the flag must beat the variable, which must beat `auto`.
    func testTheFlagBeatsTheVariableWhichBeatsAuto() {
        XCTAssertTrue(TmuxPassthrough.resolve(flag: .on, env: ["TERM": "xterm-256color"]).on)
        XCTAssertFalse(TmuxPassthrough.resolve(flag: .off, env: ["TERM": "tmux-256color"]).on)
        XCTAssertTrue(TmuxPassthrough.resolve(flag: nil, env: ["TERM": "xterm-256color",
                                                               "KRD_PASSTHROUGH": "on"]).on)
        XCTAssertFalse(TmuxPassthrough.resolve(flag: nil, env: ["TERM": "tmux-256color",
                                                                "KRD_PASSTHROUGH": "off"]).on)
        XCTAssertTrue(TmuxPassthrough.resolve(flag: .on, env: ["TERM": "xterm-256color",
                                                               "KRD_PASSTHROUGH": "off"]).on,
                      "--passthrough on must win over a stray KRD_PASSTHROUGH=off")
        // A typo in the variable falls through to auto rather than silently pinning a mode.
        XCTAssertTrue(TmuxPassthrough.resolve(flag: nil, env: ["TERM": "tmux-256color",
                                                               "KRD_PASSTHROUGH": "yes"]).on)
    }

    // MARK: the writer

    /// One 3x2 placeholder panel through a real `ScreenWriter`, as a byte stream.
    private func panelStream(passthrough: Bool) -> [UInt8] {
        let writer = ScreenWriter()
        writer.passthrough = passthrough
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()
        writer.beginFrame()
        let pixels = [UInt8](repeating: 0x40, count: 3 * 2 * 4)
        writer.emitPanelAsPlaceholder(id: 5000, placementID: 9000, row: 2, col: 4,
                                      cols: 3, rows: 2, pixels: pixels, width: 3, height: 2,
                                      level: 3, paneCols: 10, paneRows: 5)
        writer.endFrame()
        writer.endSession()
        return bytes
    }

    /// The whole claim of the feature in one assertion: put the wrapped stream through the inverse
    /// envelope and you get the unwrapped stream, byte for byte. Nothing else moved — not `?2026h/l`,
    /// not the placeholder cells, not a single base64 character.
    func testWrappingTheStreamAddsEnvelopesAndChangesNothingElse() {
        let off = panelStream(passthrough: false)
        let on = panelStream(passthrough: true)
        XCTAssertFalse(String(decoding: off, as: UTF8.self).contains(TmuxPassthrough.prefix))
        XCTAssertTrue(String(decoding: on, as: UTF8.self).contains(TmuxPassthrough.prefix))
        XCTAssertEqual(strip(on), off, "the wrapped stream is the raw stream plus envelopes")
        XCTAssertGreaterThan(on.count, off.count)
        // Every APC that was raw in the unwrapped stream is inside an envelope now: none may stay
        // bare, because tmux eats a bare one and the pane goes back to tofu.
        XCTAssertEqual(envelopes(in: on), countAPCs(off),
                       "\(countAPCs(off)) APCs in the raw stream, \(envelopes(in: on)) envelopes")
    }

    /// The delete path too: leaving a tmux pane must not leave the last picture on it (a placement
    /// outlives its process — docs/design-overview.md §P3b).
    func testTheDeleteIsWrappedAsWell() {
        let writer = ScreenWriter()
        writer.passthrough = true
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.clear()
        let out = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(out.contains(TmuxPassthrough.prefix))
        XCTAssertTrue(out.contains("Ga=d,d=a"))
        XCTAssertTrue(out.contains("\u{1B}\u{1B}\\"),
                      "the delete's own ST is doubled inside the envelope: \(out.debugDescription)")
    }

    // MARK: the sink (issue #107 rework: the envelope must not be bypassable)

    /// The guard the sink uses, and proof it has teeth. Before the rework the probe's `a=t`/`a=p`/
    /// `a=d` and `KRD_DELTEST`'s lone `a=d` were written straight to fd 1 — this predicate says
    /// `false` for exactly those bytes, which is what makes the assertion below meaningful.
    func testTheEnvelopeAuditorAcceptsOnlyFullyWrappedStreams() {
        let raw = Array("\(esc)_Ga=t,f=24,s=1,v=1,q=2,i=31;AAAA\(esc)\\".utf8)
        let wrapped = Array(TmuxPassthrough.wrap("\(esc)_Ga=t,f=24,s=1,v=1,q=2,i=31;AAAA\(esc)\\").utf8)
        XCTAssertTrue(GraphicsAPC.isFullyEnveloped(wrapped))
        XCTAssertFalse(GraphicsAPC.isFullyEnveloped(raw), "a bare APC is what tmux eats")
        XCTAssertFalse(GraphicsAPC.isFullyEnveloped(wrapped + raw), "one bare APC spoils the stream")
        XCTAssertFalse(GraphicsAPC.isFullyEnveloped(raw + wrapped), "position does not matter")
        // An undoubled ESC inside an envelope: not followed by `\`, so tmux could not un-double it
        // and the payload's own end would be up for grabs.
        let loneEscape = TmuxPassthrough.prefix + "Ga=t\(esc)X" + TmuxPassthrough.terminator
        XCTAssertFalse(GraphicsAPC.isFullyEnveloped(Array(loneEscape.utf8)),
                       "a lone ESC inside the envelope is not a payload byte tmux can restore")
        // An envelope left open would swallow whatever krd sends next.
        XCTAssertFalse(GraphicsAPC.isFullyEnveloped(Array(TmuxPassthrough.open.utf8) + Array("Ga=t".utf8)))
    }

    /// A captured stream from the real emitter: every APC in it is enveloped, asserted by the same
    /// parser the sink itself runs. This is the regression net — a future tenth emission site that
    /// appends `ESC _ G…` by hand fails here even if it forgets the flag, and
    /// `ScreenWriter.flushLocked` asserts the identical predicate at runtime.
    func testEveryAPCInACapturedStreamIsEnveloped() {
        let off = panelStream(passthrough: false)
        let on = panelStream(passthrough: true)
        XCTAssertFalse(GraphicsAPC.isFullyEnveloped(off),
                       "with the flag off the stream stays raw: that is the byte-identical contract")
        XCTAssertTrue(GraphicsAPC.isFullyEnveloped(on),
                      "\(envelopes(in: on)) envelopes for \(countAPCs(off)) APCs")
    }

    // MARK: helpers

    /// Strip every `\ePtmux;` envelope back to the sequence tmux would forward, leaving every other
    /// byte where it was. A lone `ESC` inside an envelope means the envelope's end — that is exactly
    /// how tmux reads it.
    private func strip(_ stream: [UInt8]) -> [UInt8] {
        let prefix = Array(TmuxPassthrough.prefix.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < stream.count {
            guard i + prefix.count <= stream.count,
                  Array(stream[i..<(i + prefix.count)]) == prefix else {
                out.append(stream[i])
                i += 1
                continue
            }
            i += prefix.count
            var closed = false
            while i < stream.count {
                if stream[i] == 0x1B {
                    if i + 1 < stream.count, stream[i + 1] == 0x1B {
                        out.append(0x1B)
                        i += 2
                        continue
                    }
                    XCTAssertEqual(i + 1 < stream.count ? stream[i + 1] : 0, 0x5C,
                                   "the envelope must end with ESC \\")
                    i += 2
                    closed = true
                    break
                }
                out.append(stream[i])
                i += 1
            }
            XCTAssertTrue(closed, "an envelope that never closes would swallow the pane")
        }
        return out
    }

    private func envelopes(in stream: [UInt8]) -> Int {
        let prefix = Array(TmuxPassthrough.prefix.utf8)
        guard stream.count >= prefix.count else { return 0 }
        return (0...(stream.count - prefix.count)).reduce(0) { count, i in
            Array(stream[i..<(i + prefix.count)]) == prefix ? count + 1 : count
        }
    }

    /// Count the raw kitty-graphics APCs in a stream (`ESC _ G`): the corpus of things that must all
    /// end up inside an envelope when passthrough is on.
    private func countAPCs(_ stream: [UInt8]) -> Int {
        let marker = Array("\u{1B}_G".utf8)
        guard stream.count >= marker.count else { return 0 }
        return (0...(stream.count - marker.count)).reduce(0) { count, i in
            Array(stream[i..<(i + marker.count)]) == marker ? count + 1 : count
        }
    }
}
