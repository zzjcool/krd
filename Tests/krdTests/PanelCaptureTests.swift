import XCTest
import Foundation
import ScreenCaptureKit
@testable import krd

/// The half of `PanelCapture` that needs no screen: which failure a thrown error becomes, and the
/// id → item rule both capture paths share.
///
/// `SCScreenshotManager` itself is not reached here — it needs a grant and a screen. What is pinned
/// is the policy, because that is where a wrong answer stays invisible: `.denied` and `.failed`
/// draw the same mask, so only these tests (and the log line the next morning) can tell them apart.
final class PanelCaptureTests: XCTestCase {
    /// Stand-in for `SCWindow`/`SCDisplay`, which have no public initialiser: the rule under test
    /// is "the id decides", and it does not care what the item is.
    private struct Item: Equatable {
        let id: UInt32
        let name: String
    }

    private func find(_ id: UInt32, _ items: [Item]) -> Item? {
        PanelCapture.find(id, in: items, id: { $0.id })
    }

    // MARK: - id matching

    func testTheItemWithTheIdIsFound() {
        let items = [Item(id: 7, name: "front"), Item(id: 9, name: "back")]
        XCTAssertEqual(find(9, items), Item(id: 9, name: "back"))
    }

    func testAnIdThatIsNotInTheListIsNil() {
        let items = [Item(id: 7, name: "front"), Item(id: 9, name: "back")]
        XCTAssertNil(find(8, items))
        XCTAssertNil(find(8, []), "an empty world must not match anything, least of all the first item")
    }

    /// Two windows can report the same id (a re-created window, a stale enumeration); the list is
    /// ordered front to back, so the first one is the one the reader pointed at, and the picture
    /// must be that one — never the last, and never a merge.
    func testTheFirstOfTwoItemsWithTheSameIdWins() {
        let front = [Item(id: 7, name: "front"), Item(id: 7, name: "back")]
        XCTAssertEqual(find(7, front), Item(id: 7, name: "front"))
        let back = [Item(id: 7, name: "back"), Item(id: 7, name: "front")]
        XCTAssertEqual(find(7, back), Item(id: 7, name: "back"), "the rule is position, not the name")
    }

    // MARK: - classify

    private func scError(_ code: Int) -> NSError {
        NSError(domain: SCStreamErrorDomain, code: code)
    }

    func testUserDeclinedIsDenied() {
        XCTAssertEqual(PanelCapture.classify(scError(-3801)), .denied)   // SCStreamErrorUserDeclined
    }

    func testMissingEntitlementIsDenied() {
        // Same answer as -3801, with no dialog in between: the reader cannot act on the difference.
        XCTAssertEqual(PanelCapture.classify(scError(-3803)), .denied)   // SCStreamErrorMissingEntitlements
    }

    /// The one code the capture call itself reports as "that window is gone" — the card gets a mask
    /// and a click retries, exactly like a window that failed to resolve up front.
    func testNoWindowListMeansTheWindowIsGone() {
        XCTAssertEqual(PanelCapture.classify(scError(-3813)), .windowGone)   // SCStreamErrorNoWindowList
    }

    /// A refused start is a transient fault, not a permission answer: if this became `.denied` the
    /// wall would stop retrying a stream that would have recovered.
    func testAStartFailureIsNotADenial() {
        for code in [-3802, -3804] {
            guard case .failed(let message) = PanelCapture.classify(scError(code)) else {
                return XCTFail("-\(code) must classify as .failed, not as a policy answer")
            }
            XCTAssertFalse(message.isEmpty, "the message is the only thing the log will carry")
        }
    }

    /// The domain decides, not the number: an unrelated framework's `-3801` is not a Screen
    /// Recording refusal, and treating it as one would silently disable a panel.
    func testAForeignDomainKeepsItsMessageAndLosesOnlyItsType() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "boom"])
        XCTAssertEqual(PanelCapture.classify(cocoa), .failed("boom"))

        let impostor = NSError(domain: "com.example.other", code: -3801,
                               userInfo: [NSLocalizedDescriptionKey: "not TCC"])
        XCTAssertEqual(PanelCapture.classify(impostor), .failed("not TCC"))
    }

    /// `capture` re-classifies whatever it catches, and a caller may retry with an error it already
    /// holds; either way a `PanelCaptureError` must come back unchanged (it is `Equatable` so the
    /// wall's mask can be asserted against a value, not a string).
    func testOurOwnErrorsPassThroughUnchanged() {
        for error: PanelCaptureError in [.windowGone, .denied, .noPixelBuffer, .failed("nope")] {
            XCTAssertEqual(PanelCapture.classify(error), error)
        }
    }

    /// A mask is the same rectangle whatever went wrong, so the label inside it is the only place a
    /// reader learns *why* - and it has to fit in a card that can be 20 cells wide.
    func testEveryFailureHasAShortLabelForTheMask() {
        XCTAssertEqual(PanelCaptureError.windowGone.maskLabel, "closed")
        XCTAssertEqual(PanelCaptureError.denied.maskLabel, "denied")
        XCTAssertEqual(PanelCaptureError.noPixelBuffer.maskLabel, "no pixels")
        // `-3805` is the window server refusing a window, not a missing permission: naming it
        // "denied" would send the reader to System Settings for nothing.
        XCTAssertEqual(PanelCaptureError.failed("SCStream -3805: Failed during stream").maskLabel,
                       "no stream")
        XCTAssertEqual(PanelCaptureError.failed("something else").maskLabel, "failed")
        for label in [PanelCaptureError.windowGone.maskLabel,
                      PanelCaptureError.denied.maskLabel,
                      PanelCaptureError.noPixelBuffer.maskLabel,
                      PanelCaptureError.failed("x").maskLabel] {
            XCTAssertLessThanOrEqual(label.count, 9, "\(label) will not fit a narrow card")
        }
    }
}
