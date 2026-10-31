import XCTest
@testable import krd

/// The fingerprint: what turns the 2 s poll into a *bound* on staleness rather than a hope
/// (issue #169).
///
/// The defect: a window closing inside the app that is already frontmost posts no `NSWorkspace`
/// notification — nothing launched, quit, activated, hid or changed space, so `WallWatch` stays
/// silent and the card stayed on the wall hit-testing a window number that no longer exists until
/// some unrelated system event happened to arrive. Nothing bounded that wait. A poll can only bound
/// it if the cheap thing it reads cannot *miss* a change an enumeration would have shown, so every
/// test below is one way a window set can move, checked against the fields the fingerprint carries:
///
/// - `windows` (the on-screen count) alone cannot: one window closing while another opens leaves
///   the count where it was,
/// - `ids` (the sum of the window numbers) can, because the window server never reuses a number,
///   so a swap in and a swap out cannot cancel out of a sum,
/// - `frontmost` (the front app's pid, 0 when none) covers a pure reorder, which is a different
///   wall with the same membership because the shelf is most-recently-used first,
/// - `displays` (the active display ids, sorted) covers a plug/unplug/rearrange, which changes the
///   stage's aspect and the card capacity without moving a single window.
///
/// Pure: no window server, no AppKit, no `CGWindowListCopyWindowInfo` — every case is a struct
/// literal, and the question "does the poll see it?" is the same `shouldEnumerate` the wall asks.
final class WallFingerprintTests: XCTestCase {
    /// Three windows (numbers 5107, 5112, 5119 — `ids` is their sum, exactly what
    /// `WallSource.fingerprint()` carries) on the built-in display, `Terminal` (pid 501) in front.
    private let drawn = WallFingerprint(windows: 3, ids: 5107 + 5112 + 5119, frontmost: 501,
                                       displays: [1])

    /// Does the backstop see it? Spelled once so that every case below reads as the same question.
    private func pollSees(_ now: WallFingerprint, drawn: WallFingerprint?) -> Bool {
        WallRefresh.shouldEnumerate(.poll, now: now, drawn: drawn)
    }

    /// The bug of #169 in one fingerprint: `Terminal` is already frontmost, the wall sits behind it,
    /// and one of its windows closes. No app activates, quits or hides, so AppKit announces nothing.
    func testAWindowClosingInsideTheFrontmostAppMovesTheFingerprint() {
        let after = WallFingerprint(windows: 2, ids: 5107 + 5112, frontmost: 501, displays: [1])
        XCTAssertNotEqual(after, drawn)
        // Both halves of the window set moved, and the app did not: that is the whole case, and it
        // is why `windows` and `ids` are both carried.
        XCTAssertEqual(drawn.windows, 3)
        XCTAssertEqual(after.windows, 2)
        XCTAssertNotEqual(after.ids, drawn.ids)
        XCTAssertEqual(after.frontmost, drawn.frontmost)
        XCTAssertEqual(after.displays, drawn.displays)
        // Seen, so the bound is real for the change nothing announces.
        XCTAssertTrue(pollSees(after, drawn: drawn))
    }

    /// A count-only fingerprint would call this "unchanged": the app opened a window in the same
    /// breath as it closed one, so `windows` reads the same before and after. The sum of window
    /// numbers is the field that makes "one in, one out" visible — window numbers are handed out
    /// monotonically and never reused, so 5119 leaving and 5126 arriving cannot cancel.
    func testOneClosedWhileAnotherOpenedIsCaughtByTheIdSum() {
        let after = WallFingerprint(windows: 3, ids: 5107 + 5112 + 5126, frontmost: 501,
                                    displays: [1])
        // The trap in full: the count is identical, so anything comparing only `windows` concludes
        // "nothing happened" and keeps a card for a window that is gone.
        XCTAssertEqual(after.windows, drawn.windows)
        XCTAssertNotEqual(after.ids, drawn.ids)
        XCTAssertNotEqual(after, drawn)
        XCTAssertTrue(pollSees(after, drawn: drawn))
    }

    /// The shelf is most-recently-used first, so a pure focus change (cmd-tab between two apps that
    /// own the same windows) is a different wall with the same membership, the same count and the
    /// same id sum. `frontmost` is the only field that moves, and it has to be enough.
    func testAFrontmostChangeIsSeenEvenWhenTheWindowSetIsIdentical() {
        let refocused = WallFingerprint(windows: drawn.windows, ids: drawn.ids, frontmost: 502,
                                        displays: drawn.displays)
        XCTAssertNotEqual(refocused, drawn)
        XCTAssertEqual(refocused.windows, drawn.windows)
        XCTAssertEqual(refocused.ids, drawn.ids)
        XCTAssertTrue(pollSees(refocused, drawn: drawn))
        // "No app is frontmost" is a real state (`frontmost: 0`, e.g. the desktop is focused), not
        // an unknown: it must differ from a pid rather than collapse into "don't care".
        let noneFrontmost = WallFingerprint(windows: drawn.windows, ids: drawn.ids, frontmost: 0,
                                            displays: drawn.displays)
        XCTAssertNotEqual(noneFrontmost, refocused)
        XCTAssertTrue(pollSees(noneFrontmost, drawn: drawn))
    }

    /// A display plug/unplug moves no window and changes no app, so the window set cannot report
    /// it, but it is a different wall all the same: the stage's aspect and the card capacity come
    /// from the display set.
    func testADisplayPlugOrUnplugIsSeen() {
        let twoScreens = WallFingerprint(windows: drawn.windows, ids: drawn.ids,
                                         frontmost: drawn.frontmost, displays: [1, 3])
        // A plug: one display more, not one window more.
        XCTAssertTrue(pollSees(twoScreens, drawn: drawn))
        // An unplug: the same windows with one display fewer left behind.
        XCTAssertTrue(pollSees(drawn, drawn: twoScreens))
        XCTAssertNotEqual(twoScreens, drawn)
        // Same count, different display: a laptop screen leaving as an external one arrives.
        let swapped = WallFingerprint(windows: drawn.windows, ids: drawn.ids,
                                      frontmost: drawn.frontmost, displays: [1, 4])
        XCTAssertTrue(pollSees(swapped, drawn: twoScreens))
    }

    /// The poll's entire cost argument: reading the fingerprint twice must answer "nothing moved",
    /// so an idle wall pays one cheap read per 2 s and never enumerates.
    func testTwoIdenticalFingerprintsAreNotSeen() {
        let same = WallFingerprint(windows: 3, ids: 5107 + 5112 + 5119, frontmost: 501,
                                   displays: [1])
        XCTAssertEqual(same, drawn)
        XCTAssertFalse(pollSees(same, drawn: drawn))
        // Nor does the wall's own input pay for an enumeration: a click is not evidence that the
        // world moved, so a click on an unchanged world stays as cheap as the idle second around
        // it.
        XCTAssertFalse(WallRefresh.shouldEnumerate(.input, now: same, drawn: drawn))
    }

    /// The gate is an `!=` on this struct, so a field left out of the equality would be a change the
    /// poll cannot see — the bound would silently stop covering it. Each field is asserted on its
    /// own, with the rest held fixed.
    func testEveryFieldIsPartOfTheEquality() {
        let changedWindows = WallFingerprint(windows: 4, ids: drawn.ids,
                                             frontmost: drawn.frontmost, displays: drawn.displays)
        let changedIDs = WallFingerprint(windows: drawn.windows, ids: drawn.ids + 1,
                                         frontmost: drawn.frontmost, displays: drawn.displays)
        let changedFrontmost = WallFingerprint(windows: drawn.windows, ids: drawn.ids,
                                               frontmost: 502, displays: drawn.displays)
        let changedDisplays = WallFingerprint(windows: drawn.windows, ids: drawn.ids,
                                              frontmost: drawn.frontmost, displays: [1, 2])
        let cases: [(String, WallFingerprint)] = [("windows", changedWindows), ("ids", changedIDs),
                                                  ("frontmost", changedFrontmost),
                                                  ("displays", changedDisplays)]
        for (field, other) in cases {
            XCTAssertNotEqual(drawn, other, "a changed \(field) must not compare equal")
            XCTAssertTrue(pollSees(other, drawn: drawn), "a changed \(field) must be seen")
        }
        // The memberwise initialiser is part of the frozen surface: what was written is what is
        // read back, in order, with `displays` an `[UInt32]` of sorted ids the producer keeps
        // sorted.
        XCTAssertEqual(drawn.windows, 3)
        XCTAssertEqual(drawn.ids, 15338)
        XCTAssertEqual(drawn.frontmost, 501)
        XCTAssertEqual(drawn.displays, [UInt32(1)])
        // Element-wise all the way, so two fingerprints can never differ only in the order their
        // display ids happen to be written in without `!=` saying so.
        let sorted = WallFingerprint(windows: drawn.windows, ids: drawn.ids,
                                     frontmost: drawn.frontmost, displays: [UInt32(1), 3])
        let writtenBackwards = WallFingerprint(windows: drawn.windows, ids: drawn.ids,
                                               frontmost: drawn.frontmost,
                                               displays: [UInt32(3), 1])
        XCTAssertNotEqual(sorted, writtenBackwards)
    }
}
