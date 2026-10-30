import XCTest
@testable import krd

/// `WallSource.ordered` is the only part of the enumeration that is a decision rather than a
/// translation: which display the stage shows first, and what index a click's `enterStage` payload
/// means. Screen geometry cannot be faked in a test, so the policy takes plain tuples.
final class WallSourceTests: XCTestCase {
    private typealias Entry = (name: String, minX: Double, main: Bool)

    private func names(_ entries: [Entry], _ order: [Int]) -> [String] {
        order.map { entries[$0].name }
    }

    func testTheMainDisplayComesFirstEvenInTheMiddle() {
        let entries: [Entry] = [("left", -1512, false), ("built-in", 0, true), ("right", 1512, false)]
        XCTAssertEqual(names(entries, WallSource.ordered(entries)), ["built-in", "left", "right"])
        // Not merely "the main display is somewhere in front": the order is exactly this one.
        XCTAssertEqual(WallSource.ordered(entries), [1, 0, 2])
    }

    func testWithoutAMainDisplayItIsLeftToRight() {
        let entries: [Entry] = [("c", 300, false), ("a", 100, false), ("b", 200, false)]
        XCTAssertEqual(names(entries, WallSource.ordered(entries)), ["a", "b", "c"])
    }

    func testANegativeMinXSortsLeftOfTheOrigin() {
        // A display to the left of the main one has a negative frame.minX; it is still "left".
        let entries: [Entry] = [("main", 0, true), ("far-left", -2560, false), ("near-left", -1600, false),
                                ("right", 1920, false)]
        XCTAssertEqual(names(entries, WallSource.ordered(entries)),
                       ["main", "far-left", "near-left", "right"])
    }

    func testEqualMinXKeepsTheInputOrder() {
        // Mirrored displays, or two screens whose frames start at the same x.
        let entries: [Entry] = [("first", 100, false), ("second", 100, false), ("third", 100, false)]
        XCTAssertEqual(names(entries, WallSource.ordered(entries)), ["first", "second", "third"])
        // ...and main still wins the tie, wherever it is in the list.
        let withMain: [Entry] = [("mirror", 100, false), ("main", 100, true)]
        XCTAssertEqual(names(withMain, WallSource.ordered(withMain)), ["main", "mirror"])
    }

    func testEmptyInputIsAnEmptyOrder() {
        XCTAssertEqual(WallSource.ordered([]), [])
    }

    func testTheOrderIsAPermutationOfEveryIndex() {
        let entries: [Entry] = [("d", 40, false), ("main", 10, true), ("b", 10, false), ("a", -10, false)]
        let order = WallSource.ordered(entries)
        XCTAssertEqual(order.sorted(), Array(entries.indices))
    }
}
