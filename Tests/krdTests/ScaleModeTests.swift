import XCTest
@testable import krd

/// `--scale` defaults to `auto` (issue #73), and the paths that must be reproducible pin it to 1.
///
/// The asymmetry that makes `auto` the right default: it starts at 1 and only steps *down* when the
/// write side cannot keep up, so a fast link never sees a different picture, while a slow one trades
/// sharpness for motion instead of freezing. Freezing is the failure a user can neither explain nor
/// fix -- the flag is not something they know about.
///
/// These tests exist because "the default is 1" is easy to keep by accident: every test that captures
/// at 1 would also pass if the default were still a fixed 1, so the default itself is asserted here.
final class ScaleModeTests: XCTestCase {
    private func parse(_ args: String...) -> Options {
        parseArguments(["krd"] + args)
    }

    func testTheDefaultIsAdaptive() {
        let options = self.parse()
        XCTAssertTrue(options.scaleAuto, "an unadorned run must adapt to the pipe")
        XCTAssertEqual(options.scale, 1, "and start where a fast link stays")
        XCTAssertFalse(options.scalePinned)
        XCTAssertNil(options.scaleError)
    }

    func testExplicitAutoIsTheSameAsTheDefault() {
        let options = self.parse("--scale", "auto")
        XCTAssertTrue(options.scaleAuto)
        XCTAssertFalse(options.scalePinned)
        XCTAssertEqual(options.scale, 1)
    }

    func testAFractionPinsIt() {
        for value in ["1", "0.5", "0.25"] {
            let options = self.parse("--scale", value)
            XCTAssertFalse(options.scaleAuto, "--scale \(value) must not adapt")
            XCTAssertTrue(options.scalePinned)
            XCTAssertEqual(options.scale, Double(value)!, accuracy: 0.0001)
        }
    }

    /// The escape hatch is `--scale 1`, and it has to be distinguishable from "no flag at all" --
    /// otherwise `--selftest` cannot refuse it and `adaptiveScaleRefusal` cannot stay quiet.
    func testPinnedOneIsNotTheSameAsTheDefault() {
        XCTAssertTrue(parse().scaleAuto)
        XCTAssertFalse(parse("--scale", "1").scaleAuto)
    }

    func testABadValueIsAnErrorNotASilentOne() {
        for value in ["2", "0", "-1", "half", ""] {
            let options = self.parse("--scale", value)
            XCTAssertNotNil(options.scaleError, "--scale \(value) should be refused")
        }
    }

    // MARK: the four reproducible paths

    func testReproduciblePathsRefuseToAdapt() {
        let paths: [(String, () -> String?)] = [
            ("--bench", { adaptiveScaleRefusal(bench: true, selftest: false, recording: false, replay: false) }),
            ("--selftest", { adaptiveScaleRefusal(bench: false, selftest: true, recording: false, replay: false) }),
            ("--record", { adaptiveScaleRefusal(bench: false, selftest: false, recording: true, replay: false) }),
            ("--replay", { adaptiveScaleRefusal(bench: false, selftest: false, recording: false, replay: true) }),
        ]
        for (name, note) in paths {
            let line = note()
            XCTAssertNotNil(line, "\(name) must pin the scale")
            XCTAssertTrue(line!.contains("scale 1"), "\(name): \(line!)")
        }
    }

    func testALiveSessionMayAdapt() {
        XCTAssertNil(adaptiveScaleRefusal(bench: false, selftest: false, recording: false, replay: false),
                     "the whole point of the default: a live capture reacts to the pipe")
    }

    /// A pinned fraction stays allowed where it is constant, so `--record --scale 0.5` still records.
    func testAPinnedFractionIsNotRefused() {
        XCTAssertNil(adaptiveScaleRefusal(bench: false, selftest: false, recording: false, replay: false))
        let options = parse("--record", "/tmp/x", "--scale", "0.5")
        XCTAssertTrue(options.scalePinned)
        XCTAssertEqual(options.scale, 0.5)
    }

    // MARK: --dev must show a resolution that moves on its own

    func testTheStatusLineShowsTheScaleOnlyWhenItIsNotOne() {
        func bar(scale: Double, auto: Bool, cols: Int = 120) -> String {
            var m = ChromeMetrics()
            m.target = "window 530 1024×678"
            m.fps = 19.4
            m.mbps = 3.2
            m.e2eMs = 54
            m.scale = scale
            m.scaleAuto = auto
            let geo = Chrome.layout(paneCols: cols, paneRows: 20, imageCols: cols, imageRows: 19,
                                    panel: nil)
            let bytes = Chrome().draw(geometry: geo, metrics: m, state: ChromeState())
            let text = String(decoding: bytes, as: UTF8.self)
            return text.split(separator: "\n").map(String.init).joined(separator: " ")
        }
        XCTAssertTrue(bar(scale: 0.5, auto: true).contains("0.5×"), "a scale that moved has to be visible")
        XCTAssertFalse(bar(scale: 1, auto: true).contains("1×"), "at 1 there is nothing to say")
    }
}
