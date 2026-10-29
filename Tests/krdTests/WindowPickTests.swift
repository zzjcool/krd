import XCTest
import CoreGraphics
@testable import krd
@testable import krdcore

/// Backdrop detection for `--window` (issue #24). Pure numbers, no window server: the decision is
/// "below the desktop layer and filling a display", and the layer values in these tests are the
/// ones measured on macOS 26 (`--list` with a temporary `layer=` field).
final class WindowPickTests: XCTestCase {
    /// The display from the report: `window 12 @0,0 1920x1200 app=Finder title=` captured black.
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    private func isBackdrop(layer: Int, _ frame: CGRect) -> Bool {
        WindowPick.backdrop(layer: layer, frame: frame, displays: [display]) != nil
    }

    func testTheDesktopLayerIsABackdropAtEveryMeasuredDepth() {
        XCTAssertTrue(isBackdrop(layer: -2_147_483_603, display), "Finder's desktop (empty title)")
        XCTAssertTrue(isBackdrop(layer: -2_147_483_624, display), "WindowManager wallpaper")
        XCTAssertTrue(isBackdrop(layer: -2_147_483_625, display), "offscreen wallpaper")
        XCTAssertTrue(isBackdrop(layer: -2_147_483_626, display), "per-display backstop")
    }

    /// The desktop window is inset by the menu bar and the Dock: 1418x2518 of a 1440x2560 display on
    /// the machine this was measured on. An exact-bounds test would miss the very window in the
    /// report, so the rule allows 90 %.
    func testTheDesktopInsetByMenuBarAndDockStillCounts() {
        let portrait = CGRect(x: 0, y: 0, width: 1440, height: 2560)
        let inset = CGRect(x: 11, y: 21, width: 1418, height: 2518)
        XCTAssertNotNil(WindowPick.backdrop(layer: -2_147_483_603, frame: inset, displays: [portrait]))
    }

    func testRealWindowsAreNeverBackdrops() {
        XCTAssertFalse(isBackdrop(layer: 0, display), "a normal app window")
        XCTAssertFalse(isBackdrop(layer: 24, display), "the menu bar layer")
        XCTAssertFalse(isBackdrop(layer: 2001, display), "login-window UI")
        XCTAssertFalse(isBackdrop(layer: 2_147_483_646, display), "the screen-share shield")
        // Notification-centre widgets sit just above the desktop layer; their frames are small,
        // but the layer test alone has to keep them out.
        XCTAssertFalse(isBackdrop(layer: -2_147_483_601,
                                  CGRect(x: 501, y: 235, width: 355, height: 178)))
    }

    /// Below the desktop layer but not filling the screen is a strip, not a backdrop: mirroring it
    /// is legitimate, so it must not be refused.
    func testLowLayerWindowsThatDoNotFillTheDisplayAreNotBackdrops() {
        XCTAssertFalse(isBackdrop(layer: -2_147_483_603, CGRect(x: 0, y: 0, width: 1920, height: 217)))
        XCTAssertFalse(isBackdrop(layer: -2_147_483_603, CGRect(x: 0, y: 0, width: 1200, height: 1200)))
        XCTAssertFalse(isBackdrop(layer: -2_147_483_603, .zero))
    }

    func testTheDisplayThatIsCoveredIsTheOneReported() {
        let second = CGRect(x: 1920, y: 0, width: 1512, height: 982)
        let covered = WindowPick.backdrop(layer: -2_147_483_626, frame: second,
                                          displays: [display, second])
        XCTAssertEqual(covered, second)
        XCTAssertEqual(WindowPick.backdrop(layer: -2_147_483_626, frame: display,
                                           displays: [display, second]), display)
    }
}
