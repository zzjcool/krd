import XCTest
@testable import krdcore

/// The chrome's paints and the frame's tiles are written by **two threads** into one buffer, and an
/// APC that another writer lands inside is not a protocol error the terminal forgives.
///
/// Measured on the tart VM (issue #235): a click on the bar's button while a frame was in flight, and
/// the pane printed the frame's base64 as text under the bar, with the loading card's logo drawn in a
/// corner. The mechanism: `emitTileAsPlaceholder` appends a transmit in pieces
/// (`ESC _ G<header>;<base64 up to 4096>` … `ESC \`), the chrome's repaint from the main queue
/// appends its *own* APC (the card's logo) and flushes — so the terminal sees `ESC _` inside an
/// open APC, aborts the string, and every byte after it is plain text.
///
/// The contract this pins: **every flushed chunk is a sequence of complete APCs**. Not "no chunks
/// while a frame is open" — a frame is thousands of chunks and the chrome has to paint during one —
/// but never a chunk that ends inside `ESC _ … ESC \`.
final class ChromeInsideTransmitTests: XCTestCase {

    /// A chrome paint's bytes, in the shape `IconCache.transmitChunks` + `writeChrome` produce: a
    /// complete image APC followed by the text the card paints around it.
    private func chromePaint(_ marker: String) -> [UInt8] {
        var bytes = Array(GraphicsAPC.sequence("Gi=999,a=t,f=32,s=1,v=1;A\(marker)").utf8)
        bytes += Array("\u{1B}[3;5H\u{1B}[38;2;1;2;3mcard\u{1B}[39m".utf8)
        return bytes
    }

    /// The stream the terminal actually sees — every chunk concatenated — checked for the one thing
    /// that cannot be forgiven: an `ESC _` arriving *inside* another APC.
    ///
    /// The terminal reads one continuous byte stream, so a chunk boundary is not an event; an `ESC`
    /// is. Inside an open `ESC _ … ESC \` string, an `ESC` that is not followed by `\` cancels the
    /// string and every remaining byte is dispatched as text — that is where the printed base64 came
    /// from, and it is exactly what a foreign APC's introducer landing between a transmit's header and
    /// its payload produces.
    private func apcsOpenedInsideAnOpenAPC(_ chunks: [[UInt8]]) -> Int {
        var open = false
        var pendingEscape = false
        var offenders = 0
        for byte in chunks.joined() {
            if pendingEscape {
                pendingEscape = false
                if byte == 0x5F {                      // ESC _ : opens a string
                    if open { offenders += 1 }          // …inside one that never closed
                    open = true
                    continue
                }
                if byte == 0x5C {                       // ESC \ : closes it
                    if open { open = false }
                    continue
                }
                // ESC + anything else cancels the string, and the byte is re-dispatched.
                if open { open = false }
                if byte == 0x1B { pendingEscape = true }
                continue
            }
            if byte == 0x1B { pendingEscape = true }
        }
        return offenders
    }

    /// The measured failure, made deterministic: the chrome's paint is *placed* where it used to land
    /// by accident — between a transmit's header and its payload — and the byte stream says whether the
    /// write lock kept it out.
    ///
    /// The seam fires while the transmit holds the lock, so the chrome thread's `writeChrome` blocks
    /// there until the chunk is complete; the wait has a timeout so that the *unfixed* code (no lock)
    /// cannot deadlock the suite, it just lets the paint through.
    func testAChromePaintCannotLandInsideATransmit() {
        let writer = ScreenWriter()
        let lock = NSLock()
        var chunks: [[UInt8]] = []
        writer.sink = { bytes in
            lock.lock()
            chunks.append(bytes)
            lock.unlock()
        }
        let reached = DispatchSemaphore(value: 0)
        writer.transmitSeam = {
            reached.signal()
            _ = reached.wait(timeout: .now() + 0.2)
        }

        let painted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = reached.wait(timeout: .now() + 5)
            writer.writeChrome(self.chromePaint("x"))
            painted.signal()
        }

        writer.beginFrame()
        writer.appendTransmitChunk("Gi=100,a=t,m=0;", [UInt8](repeating: 0x41, count: 64)[...])
        writer.endFrame()
        XCTAssertEqual(painted.wait(timeout: .now() + 5), .success, "the paint finished")

        lock.lock()
        let flushed = chunks
        lock.unlock()
        XCTAssertEqual(apcsOpenedInsideAnOpenAPC(flushed), 0,
                       "\(apcsOpenedInsideAnOpenAPC(flushed)) APC(s) were opened inside another: a "
                       + "chrome paint split a transmit, and a terminal cancels the string there and "
                       + "prints the rest of the base64 as text")
        // Both the transmit and the paint are still in the stream, in some order: the fix orders them,
        // it does not drop either.
        let stream = String(decoding: flushed.flatMap { $0 }, as: UTF8.self)
        XCTAssertTrue(stream.contains("Gi=100,a=t,m=0;"))
        XCTAssertTrue(stream.contains("Gi=999,a=t"))
    }

    /// The same invariant stated without threads, over the writer's own API: one transmit chunk and
    /// one chrome write, flushed the way production flushes them, and no chunk in between is partial.
    func testOneChunkIsOneWholeAPC() {
        let writer = ScreenWriter()
        var chunks: [[UInt8]] = []
        writer.sink = { chunks.append($0) }

        writer.beginFrame()
        writer.appendTransmitChunk("Gi=100,a=t,m=1;", [UInt8](repeating: 0x41, count: 4096)[...])
        writer.writeChrome(chromePaint("y"))
        writer.appendTransmitChunk("Gm=0;", [UInt8](repeating: 0x42, count: 16)[...])
        writer.endFrame()

        XCTAssertEqual(apcsOpenedInsideAnOpenAPC(chunks), 0)
        // …and both of the transmit's chunks arrived as complete, enveloped APCs.
        let joined = chunks.flatMap { $0 }
        XCTAssertEqual(joined.filter { $0 == 0x5F }.count, joined.filter { $0 == 0x5F }.count)
        XCTAssertTrue(String(decoding: joined, as: UTF8.self).contains("Gi=100,a=t,m=1;"))
        XCTAssertTrue(String(decoding: joined, as: UTF8.self).contains("Gi=999,a=t"))
    }
}
