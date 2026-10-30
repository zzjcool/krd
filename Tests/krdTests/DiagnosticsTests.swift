import XCTest
@testable import krd
import krdcore

/// `--stats-json` is the same numbers as the panel, serialised (issue #52's acceptance test). These
/// check it is literally the same struct: the writer takes `ChromeMetrics`, so a new field cannot be
/// added to the panel and forgotten here — but a *format* mistake still can, which is what this
/// pins.
final class DiagnosticsTests: XCTestCase {
    private func json(_ m: ChromeMetrics, late: Int = 0, frames: Int = 0) throws -> [String: Any] {
        let path = NSTemporaryDirectory() + "krd-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try XCTUnwrap(StatsJSONWriter(path: path))
        writer.write(m, late: late, frames: frames)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").last, "one line per second")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func testTheJSONIsThePanelMetrics() throws {
        var m = ChromeMetrics()
        m.capMs = 40
        m.capP99Ms = 55
        m.pipeMs = 12.5
        m.pipeP99Ms = 20
        m.e2eMs = 52.5
        m.fps = 9.5
        m.captureFps = 10
        m.tilesPerSec = 120
        m.mbps = 0.5
        m.skippedPerSec = 2
        m.idlePerSec = 7
        m.inputMs = 3.5
        m.inputP99Ms = 9
        m.pxW = 800
        m.pxH = 600
        m.cellsW = 100
        m.cellsH = 30
        m.quality = 80
        m.scale = 0.8
        m.framesTotal = 42
        m.kbPerFrame = 21
        let object = try json(m, late: 3, frames: 5)

        XCTAssertEqual(object["cap_ms"] as? Double, 40)
        XCTAssertEqual(object["cap_p99_ms"] as? Double, 55)
        XCTAssertEqual(object["pipe_ms"] as? Double, 12.5)
        XCTAssertEqual(object["pipe_p99_ms"] as? Double, 20)
        XCTAssertEqual(object["e2e_ms"] as? Double, 52.5, "the number the panel prints as `frame`")
        XCTAssertEqual(object["fps"] as? Double, 9.5)
        XCTAssertEqual(object["capture_fps"] as? Double, 10)
        XCTAssertEqual(object["tiles"] as? Int, 120, "`tiles` is a rate, `tiles_total` is the counter")
        XCTAssertEqual(object["tiles_total"] as? Int, 42)
        XCTAssertEqual(object["skipped_per_s"] as? Double, 2)
        XCTAssertEqual(object["idle_per_s"] as? Double, 7)
        XCTAssertEqual(object["input_ms"] as? Double, 3.5)
        XCTAssertEqual(object["input_p99_ms"] as? Double, 9)
        XCTAssertEqual(object["mbps"] as? Double, 0.5)
        XCTAssertEqual(object["late"] as? Int, 3)
        XCTAssertEqual(object["frames"] as? Int, 5)
        XCTAssertEqual(object["quality"] as? Int, 80)
        XCTAssertEqual(object["scale"] as? Double, 0.8)
        XCTAssertEqual((object["px"] as? [Int]) ?? [], [800, 600])
        XCTAssertEqual((object["cells"] as? [Int]) ?? [], [100, 30])
    }

    /// The stats panel's third row is the split: `cap` is the capture's own share and must say so
    /// when it is unknown, rather than print `-1` as if it were a duration.
    private func statsPanel(_ m: ChromeMetrics) -> String {
        let geo = Chrome.layout(paneCols: 110, paneRows: 20, imageCols: 110, imageRows: 4, panel: .stats)
        let bytes = Chrome().draw(geometry: geo, metrics: m, state: ChromeState(panel: .stats))
        guard let text = String(bytes: bytes, encoding: .utf8) else { return "" }
        // Strip the cursor/colour escapes: the row's text is what a user reads.
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: " ",
                                         options: .regularExpression)
    }

    func testThePanelNamesAnUnmeasuredCaptureAsUnknown() {
        var m = ChromeMetrics()
        m.fpsTarget = 10
        m.capMs = -1                 // mock / replay
        m.pipeMs = 1.5
        m.e2eMs = 1.5
        let panel = statsPanel(m)
        XCTAssertTrue(panel.contains("cap — (no PTS)"), panel)
        XCTAssertTrue(panel.contains("end to end") || panel.contains("frame"), panel)
    }

    func testThePanelShowsBothHalvesWhenTheCaptureIsMeasured() {
        var m = ChromeMetrics()
        m.fpsTarget = 10
        m.capMs = 40
        m.capP99Ms = 55
        m.pipeMs = 1.5
        m.pipeP99Ms = 2.5
        m.e2eMs = 41.5
        let panel = statsPanel(m)
        XCTAssertTrue(panel.contains("cap 40 p99 55"), panel)
        XCTAssertTrue(panel.contains("pipe 2 p99 2") || panel.contains("pipe 1 p99 2"), panel)
    }

    /// The mock and replay paths have no presentation timestamp. That has to reach the reader as
    /// "unmeasured", not as a very fast capture.
    func testAnUnmeasuredCaptureAgeIsMinusOneNotZero() throws {
        var m = ChromeMetrics()
        m.capMs = -1
        m.title = "mock"
        m.target = "mock"
        // The default-constructed metrics carry `nan` percentiles (nothing sampled yet); a real
        // session always fills them, so fill them here too rather than teach the writer to emit NaN.
        m.capP99Ms = 0
        m.pipeP99Ms = 0
        m.zlibP99Ms = 0
        m.inputP99Ms = 0
        let object = try json(m)
        XCTAssertEqual(object["cap_ms"] as? Double, -1, "the reader has to be able to tell")
        XCTAssertEqual(m.capLabel, "—", "and the panel/report must not print -1 as a duration")
        XCTAssertEqual(m.capP99Label, "—")
        m.capMs = 40
        XCTAssertEqual(m.capLabel, "40.0")
    }
}
