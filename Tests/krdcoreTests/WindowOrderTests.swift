import XCTest
@testable import krdcore

/// `WindowOrder.recent` against the two `CGWindowListCopyWindowInfo` lists it was written for.
///
/// The host list is the whole reason that function exists: the system interleaves layer-0
/// `WindowManager` overlays with the windows they cover, at *identical* rectangles, so "layer 0"
/// and "at least 40x40" both keep them and only the regular-app pid rule removes them
/// (`docs/design-overview.zh-CN.md` §3). The fixture is that list unedited, which also lets this
/// suite pin the three numbers in `WindowOrder.swift`'s doc comment — 43 entries, 37 at layer 0,
/// 22 `WindowManager`-owned — and the 15 survivors.
///
/// Everything asserted *about* a fixture is hard-coded rather than recomputed through
/// `WindowOrder`: a rule re-derived in the test agrees with itself no matter what the
/// implementation does. The two places that read the fixture directly are the overlay pair loop
/// (it has to walk every real pair, not one hand-picked one) and the "nothing that should have
/// survived went missing" cross-check, and both use plain dictionary reads.
///
/// The numbers below were transcribed from the fixtures with a throwaway script, not by calling
/// the implementation: `regularPIDs` is every pid whose owner name is not one of the five system
/// owners, and the expected survivor list is the 15 windows that pass the contract's rules.
final class WindowOrderTests: XCTestCase {

    // MARK: - Fixtures and helpers

    /// Loaded through `#filePath` like `GoldenDumpTests`: no resources bundle, so the fixture is
    /// found from the source tree and a missing one fails loudly instead of yielding an empty list
    /// that would make half this suite pass vacuously.
    private func fixture(_ name: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cgwindowlist-\(name).json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [[String: Any]], "\(name): not a list of dictionaries")
    }

    /// The 11 pids of the apps with a Dock icon in the host list: every pid whose owner name is not
    /// one of the five system owners. `93439` (`WindowManager`) is deliberately absent — that
    /// absence is what rule 2 keys on.
    private let hostRegularPIDs: Set<Int32> = [
        20316, 21825, 26465, 38773, 38886, 41379, 47944, 52282, 55810, 67529, 92976,
    ]

    /// The pid a hand-built dictionary uses unless a test says otherwise, and the set that makes it
    /// "a regular app".
    private let regularPID: Int32 = 4242
    private var regularPIDs: Set<Int32> { [regularPID] }

    // Plain fixture reads. `as? Int` / `as? Double` are exactly how a `JSONSerialization` number
    // bridges, and no fixture entry needs more than that.
    private func fixtureInt(_ entry: [String: Any], _ key: String) -> Int? { entry[key] as? Int }
    private func fixtureOwner(_ entry: [String: Any]) -> String? { entry["kCGWindowOwnerName"] as? String }
    private func fixtureBounds(_ entry: [String: Any]) -> CGRectCompat? {
        guard let box = entry["kCGWindowBounds"] as? [String: Any],
              let x = box["X"] as? Double, let y = box["Y"] as? Double,
              let width = box["Width"] as? Double, let height = box["Height"] as? Double
        else { return nil }
        return CGRectCompat(x: x, y: y, width: width, height: height)
    }
    private func fixtureID(_ entry: [String: Any]) -> UInt32? {
        fixtureInt(entry, "kCGWindowNumber").flatMap { UInt32(exactly: $0) }
    }

    /// One dictionary in the shape `CGWindowListCopyWindowInfo` hands out and `JSONSerialization`
    /// reproduces. Every value is `Any` so a test can put a hostile shape in any slot, and `omit`
    /// removes keys so "the key is missing" stays distinct from "the value is null".
    private func window(layer: Any = 0, pid: Any = 4242, owner: Any = "Notes", name: Any = "Todo",
                        number: Any = 7,
                        bounds: Any = ["X": 0, "Y": 0, "Width": 100, "Height": 100],
                        omit: Set<String> = []) -> [String: Any] {
        var dictionary: [String: Any] = [
            "kCGWindowLayer": layer,
            "kCGWindowOwnerPID": pid,
            "kCGWindowOwnerName": owner,
            "kCGWindowName": name,
            "kCGWindowNumber": number,
            "kCGWindowBounds": bounds,
        ]
        for key in omit { dictionary.removeValue(forKey: key) }
        return dictionary
    }

    // MARK: - The host fixture

    /// The three numbers the doc comment in `WindowOrder.swift` states, plus the shape of the 22
    /// entries rule 2 exists to drop. If the fixture is ever re-recorded this fails first and names
    /// the claim that went stale, instead of the survivor list failing 15 ways at once.
    func testHostFixtureIsThe43EntryListTheDocCommentDescribes() throws {
        let list = try fixture("host")
        XCTAssertEqual(list.count, 43, "43 entries in the host list")
        XCTAssertEqual(list.filter { fixtureInt($0, "kCGWindowLayer") == 0 }.count, 37,
                       "37 entries are at layer 0: layer is not what separates overlays from windows")

        let windowManager = list.filter { fixtureOwner($0) == "WindowManager" }
        XCTAssertEqual(windowManager.count, 22, "22 entries are WindowManager's")
        XCTAssertEqual(windowManager.filter { fixtureInt($0, "kCGWindowLayer") == 0 }.count, 22,
                       "all 22 of them are at layer 0")

        let overlays = windowManager.filter { ($0["kCGWindowName"] as? String) == "Gesture Blocking Overlay" }
        let icons = windowManager.filter { ($0["kCGWindowName"] as? String) == "App Icon Window" }
        XCTAssertEqual(overlays.count, 12, "12 `Gesture Blocking Overlay` entries")
        XCTAssertEqual(icons.count, 9, "9 `App Icon Window` entries")
        // The 22nd is the 1x1 probe at (1e9, 1e9) whose name is JSON null.
        XCTAssertEqual(windowManager.count - overlays.count - icons.count, 1)
        XCTAssertEqual(windowManager.filter { ($0["kCGWindowBounds"] as? [String: Any]).flatMap { box in
            (box["Width"] as? Double) == 66 && (box["Height"] as? Double) == 82
        } ?? false }.count, 9,
                       "the nine app icons are 66x82 — above the 40-point floor on purpose, so the "
                       + "floor cannot be doing rule 2's work")
    }

    /// The 15 survivors, in the order the list gave them, with the titles the cards will print.
    ///
    /// Order is pinned here because it is the feature: the list is z order, front to back, and the
    /// wall shows "most recently used first". Titles are pinned because §2A rule 6 turns four
    /// `""` names (two `企业微信`, `iOA`, `YunDun`) into `nil` and must leave real ones alone —
    /// including the `App Store` title, which contains a non-breaking space and comes back
    /// untrimmed.
    func testHostFixtureKeepsExactlyTheFifteenRealWindowsInFileOrder() throws {
        let list = try fixture("host")
        let got = WindowOrder.recent(list, regularPIDs: hostRegularPIDs)

        let expected: [OrderedWindow] = [
            .init(windowID: 126324, pid: 55810, app: "Brave Browser", title: "「沒有人知道為什麼行得通」《數學教你…到不該有用 - YouTube 🔊",
                  bounds: CGRectCompat(x: 42, y: -1050, width: 1452, height: 1050)),
            .init(windowID: 124586, pid: 41379, app: "Google Chrome", title: "云监控运营平台(BARAD) - 发布管理 - 控制台 - 统一运维运营平台",
                  bounds: CGRectCompat(x: -183, y: -831, width: 192, height: 177)),
            .init(windowID: 119477, pid: 67529, app: "Rex Beta", title: "π - kkrt - hidden-vale",
                  bounds: CGRectCompat(x: 1728, y: -1050, width: 1440, height: 2530)),
            .init(windowID: 108251, pid: 38886, app: "腾讯云测试环境", title: "腾讯云测试环境 - 成都主干环境",
                  bounds: CGRectCompat(x: -176, y: -646, width: 181, height: 151)),
            .init(windowID: 78970, pid: 21825, app: "Xcode", title: "SurfaceANSIRendererTests.swift",
                  bounds: CGRectCompat(x: -176, y: -470, width: 82, height: 112)),
            .init(windowID: 119623, pid: 67529, app: "Rex Beta", title: "Settings - Developer",
                  bounds: CGRectCompat(x: 337, y: 297, width: 740, height: 572)),
            .init(windowID: 109638, pid: 38773, app: "企业微信", title: "企业微信",
                  bounds: CGRectCompat(x: 47, y: 161, width: 131, height: 182)),
            .init(windowID: 124079, pid: 38773, app: "企业微信", title: nil,
                  bounds: CGRectCompat(x: 31, y: 191, width: 97, height: 117)),
            .init(windowID: 124069, pid: 38773, app: "企业微信", title: nil,
                  bounds: CGRectCompat(x: 15, y: 191, width: 46, height: 107)),
            .init(windowID: 114083, pid: 26465, app: "WeChat", title: "Weixin",
                  bounds: CGRectCompat(x: 31, y: 348, width: 123, height: 155)),
            .init(windowID: 114299, pid: 26465, app: "WeChat", title: "Search chat history",
                  bounds: CGRectCompat(x: 16, y: 374, width: 74, height: 102)),
            .init(windowID: 53232, pid: 20316, app: "iOA", title: nil,
                  bounds: CGRectCompat(x: 15, y: 526, width: 92, height: 98)),
            .init(windowID: 94811, pid: 52282, app: "WorkBuddy", title: "WorkBuddy",
                  bounds: CGRectCompat(x: 15, y: 641, width: 161, height: 161)),
            .init(windowID: 107940, pid: 47944, app: "YunDun", title: nil,
                  bounds: CGRectCompat(x: 15, y: 806, width: 125, height: 183)),
            .init(windowID: 78652, pid: 92976, app: "App Store", title: "App\u{00A0}Store",
                  bounds: CGRectCompat(x: -176, y: -343, width: 100, height: 119)),
        ]
        XCTAssertEqual(got, expected)

        // The other direction, from the fixture alone: every layer-0 window of a regular app that
        // clears the size floor is in that list, in file order. Without this, the comparison above
        // could pass while the rule quietly dropped a sixteenth window.
        let shouldSurvive = list.compactMap { entry -> UInt32? in
            guard fixtureInt(entry, "kCGWindowLayer") == 0,
                  let pid = fixtureInt(entry, "kCGWindowOwnerPID"),
                  let regular = Int32(exactly: pid), hostRegularPIDs.contains(regular),
                  let bounds = fixtureBounds(entry),
                  bounds.width >= WindowOrder.minimumExtent,
                  bounds.height >= WindowOrder.minimumExtent
            else { return nil }
            return fixtureID(entry)
        }
        XCTAssertEqual(got.map(\.windowID), shouldSurvive)

        // An empty title means "nothing to show": never `""`, or a card renders a blank line.
        XCTAssertFalse(got.contains { $0.title == "" }, "no survivor may carry an empty title")
        XCTAssertEqual(got.filter { $0.title == nil }.map(\.windowID), [124079, 124069, 53232, 107940],
                       "the four windows whose name is \"\" in the file")
        XCTAssertEqual(got.filter { $0.pid == 38773 }.count, 3,
                       "one app owns three cards — nothing dedups by pid")
    }

    /// Every one of the 22 `WindowManager` entries is gone, and rule 2 is the only thing that can
    /// remove them: all 22 are at layer 0 and 21 of them are over the 40-point floor (only the 1x1
    /// probe is under it). A size filter keeps the 66x82 app icons; a layer filter keeps the
    /// overlays.
    func testHostFixtureDropsAllTwentyTwoWindowManagerEntriesByPID() throws {
        let list = try fixture("host")
        XCTAssertFalse(hostRegularPIDs.contains(93439), "the premise: WindowManager's pid is not in the set")

        let got = WindowOrder.recent(list, regularPIDs: hostRegularPIDs)
        let windowManager = list.filter { fixtureOwner($0) == "WindowManager" }
        let droppedIDs = windowManager.compactMap { fixtureID($0) }
        XCTAssertEqual(droppedIDs.count, 22)

        XCTAssertFalse(got.contains { $0.pid == 93439 }, "no WindowManager window survives")
        XCTAssertEqual(got.filter { droppedIDs.contains($0.windowID) }.count, 0,
                       "none of the 22 window ids is in the output")

        let overTheFloor = windowManager.filter { entry in
            guard let bounds = fixtureBounds(entry) else { return false }
            return bounds.width >= WindowOrder.minimumExtent
                && bounds.height >= WindowOrder.minimumExtent
        }
        XCTAssertEqual(overTheFloor.count, 21,
                       "21 of the 22 clear the size floor: rule 2 is what drops them, not rule 4")
    }

    /// Design §3, as a loop over the fixture: for every `WindowManager` entry whose rectangle is
    /// *identical* to a real app's window, the overlay is dropped and the real window is kept.
    ///
    /// One hand-picked pair would still pass if the rule only got that pair right; the host list
    /// has twelve such pairs, and the loop counts them so a fixture edit that removes the pairing
    /// fails here instead of turning the loop into a no-op.
    func testEveryOverlayWithIdenticalBoundsIsDroppedAndItsRealWindowKept() throws {
        let list = try fixture("host")
        let got = WindowOrder.recent(list, regularPIDs: hostRegularPIDs)

        var pairs = 0
        for overlay in list where fixtureOwner(overlay) == "WindowManager" {
            guard let rect = fixtureBounds(overlay), let overlayID = fixtureID(overlay) else { continue }
            let real = list.first { other in
                guard let owner = fixtureOwner(other), !WindowOrder.systemOwners.contains(owner),
                      fixtureBounds(other) == rect else { return false }
                return true
            }
            // The nine 66x82 app icons and the 1x1 probe have no partner: they are dropped by rule
            // 2 alone, which the test above covers.
            guard let real = real, let realID = fixtureID(real) else { continue }

            pairs += 1
            XCTAssertFalse(got.contains { $0.windowID == overlayID },
                           "the overlay \(overlayID) at \(rect) must be dropped")
            let kept = got.first { $0.windowID == realID }
            XCTAssertNotNil(kept, "the real window \(realID) sharing that rectangle must be kept")
            XCTAssertEqual(kept?.bounds, rect, "the kept window is the one under the overlay")
            XCTAssertNotEqual(kept?.pid, 93439)
        }
        XCTAssertEqual(pairs, 12, "the fixture has twelve real window / overlay pairs (design §3)")
    }

    /// Belt and braces (§2A rule 3): adding `WindowManager`'s pid to `regularPIDs` changes nothing.
    /// Rule 2 is the primary rule and is what drops the 22 today, but the name blocklist must never
    /// *keep* what a caller's pid set would have let through.
    func testAddingWindowManagersPIDToRegularPIDsChangesNothing() throws {
        let list = try fixture("host")
        let without = WindowOrder.recent(list, regularPIDs: hostRegularPIDs)
        let with = WindowOrder.recent(list, regularPIDs: hostRegularPIDs.union([93439]))

        XCTAssertEqual(with, without, "the pid rule is primary; the name rule only repeats it")
        XCTAssertEqual(with.count, 15)
        XCTAssertFalse(with.contains { $0.pid == 93439 }, "all 22 are dropped by name")

        // Not vacuous: those 22 entries now *pass* rules 1 and 2, so it is rule 3 removing them.
        XCTAssertEqual(list.filter { fixtureInt($0, "kCGWindowOwnerPID") == 93439 }.count, 22)
        XCTAssertEqual(list.filter {
            fixtureInt($0, "kCGWindowOwnerPID") == 93439 && fixtureInt($0, "kCGWindowLayer") == 0
        }.count, 22)
    }

    // MARK: - The VM fixture

    /// The short list must not be filtered by length: the VM's nine entries contain exactly one
    /// window. Handing the function *every* pid in the file proves the `Control Center` (layer 25)
    /// and `Dock` (layer 20) entries are removed by rule 1, not because their pid happened to be
    /// missing from the caller's set.
    func testVMFixtureKeepsOnlyTheLayerZeroTerminalWindow() throws {
        let list = try fixture("vm")
        XCTAssertEqual(list.count, 9)

        let got = WindowOrder.recent(list, regularPIDs: [407])
        XCTAssertEqual(got, [
            OrderedWindow(windowID: 26, pid: 407, app: "Terminal",
                          title: "admin — scroll.sh — -zsh — 95×42",
                          bounds: CGRectCompat(x: 567, y: 279, width: 702, height: 679)),
        ])

        let everyPID = Set(list.compactMap { entry -> Int32? in
            fixtureInt(entry, "kCGWindowOwnerPID").flatMap { Int32(exactly: $0) }
        })
        XCTAssertGreaterThan(everyPID.count, 1, "the fixture holds pids besides Terminal's")
        XCTAssertEqual(WindowOrder.recent(list, regularPIDs: everyPID), got)

        // The two entries the layer rule has to remove are really there, at those layers.
        XCTAssertEqual(list.filter { fixtureOwner($0) == "Dock" }.map { fixtureInt($0, "kCGWindowLayer") }, [20])
        XCTAssertEqual(list.filter { fixtureOwner($0) == "Control Center" }.map { fixtureInt($0, "kCGWindowLayer") },
                       [25, 25, 25])
        XCTAssertFalse(got.contains { $0.app == "Dock" || $0.app == "Control Center" })
    }

    // MARK: - The rules, one at a time

    /// §2A rule 6: `nil` when the key is absent, not a String, or blank — and never `""`. An empty
    /// title means "nothing to show" (the card falls back to `window N`); a whitespace-only one
    /// would render an empty second line. A real title is returned untouched: only the blank test
    /// trims, which is why the fixture's `App Store` keeps its non-breaking space.
    func testTitleIsNilWhenAbsentBlankOrNotAStringAndVerbatimOtherwise() {
        // Each case must yield *one kept window with a nil title*: `XCTAssertNil` alone would also
        // pass if the window had been dropped for some other reason.
        let cases: [(why: String, entry: [String: Any])] = [
            ("a missing key is not an empty string", window(omit: ["kCGWindowName"])),
            ("JSON null", window(name: NSNull())),
            ("the empty name four host windows have", window(name: "")),
            ("spaces only", window(name: "   ")),
            ("mixed whitespace only", window(name: " \n\t ")),
            ("a non-breaking space is whitespace too", window(name: "\u{00A0}")),
            ("not a String", window(name: 42)),
            ("not a scalar", window(name: ["a"])),
        ]
        for (why, entry) in cases {
            let kept = WindowOrder.recent([entry], regularPIDs: regularPIDs)
            XCTAssertEqual(kept.count, 1, "\(why): the window is still a card, only its title is nil")
            XCTAssertNil(kept.first?.title, why)
        }

        func title(_ entry: [String: Any]) -> String? {
            WindowOrder.recent([entry], regularPIDs: regularPIDs).first?.title
        }
        XCTAssertEqual(title(window(name: "Brave")), "Brave")
        XCTAssertEqual(title(window(name: " App\u{00A0}Store ")), " App\u{00A0}Store ",
                       "a real title comes back exactly as given, spaces and all")
    }

    /// §2A rule 4 and `minimumExtent`: 40x40 is a window, 39 on either side is not.
    func testSizeFloorKeeps40x40AndDrops39x200And200x39() {
        XCTAssertEqual(WindowOrder.minimumExtent, 40)

        let kept = WindowOrder.recent([
            window(number: 1, bounds: ["X": 0, "Y": 0, "Width": 40, "Height": 40]),
            window(number: 2, bounds: ["X": 0, "Y": 0, "Width": 100, "Height": 100]),
            window(number: 3, bounds: ["X": 0, "Y": 0, "Width": 40, "Height": 4_000]),
        ], regularPIDs: regularPIDs)
        XCTAssertEqual(kept.map(\.windowID), [1, 2, 3], "40x40 is the boundary and it is kept")

        let dropped = WindowOrder.recent([
            window(number: 4, bounds: ["X": 0, "Y": 0, "Width": 39, "Height": 200]),
            window(number: 5, bounds: ["X": 0, "Y": 0, "Width": 200, "Height": 39]),
            window(number: 6, bounds: ["X": 0, "Y": 0, "Width": 39.999, "Height": 200]),
            window(number: 7, bounds: ["X": 0, "Y": 0, "Width": 0, "Height": 0]),
        ], regularPIDs: regularPIDs)
        XCTAssertTrue(dropped.isEmpty, "39x200, 200x39 and 0x0 are not cards")
    }

    /// §2A rule 2 is the primary rule: a layer-0, 5000x5000 window with a 4 KB title from an app
    /// that is not a regular app is not a card. Handing it the pid is what flips it, so nothing
    /// else (layer, size, title) is doing the work.
    func testNonRegularPIDIsDroppedAtLayerZeroEvenWithAHugeTitle() {
        let helper = window(pid: 9001, owner: "krd-helper",
                            name: String(repeating: "x", count: 4096), number: 9,
                            bounds: ["X": -4000, "Y": -4000, "Width": 5_000, "Height": 5_000])
        XCTAssertTrue(WindowOrder.recent([helper], regularPIDs: regularPIDs).isEmpty)
        XCTAssertEqual(WindowOrder.recent([helper], regularPIDs: regularPIDs.union([9001])).map(\.windowID), [9],
                       "same dictionary, regular pid: kept — so rule 2 is what dropped it")
    }

    /// Nothing here may trap. Every dictionary is dropped and the one good window in the same call
    /// still comes back, which is also what proves a bad entry costs one window rather than the
    /// whole list.
    func testHostileDictionariesAreDroppedInsteadOfTrapping() {
        let hostile: [[String: Any]] = [
            [:],                                                     // nothing at all
            window(omit: ["kCGWindowLayer"]),                        // a missing layer is not "probably 0"
            window(layer: 1),                                        // a menu
            window(layer: -2_147_483_601),                           // a notification, far below zero
            window(layer: 0.5),                                      // not an integral layer
            window(layer: "0"),                                      // the layer as a String
            window(pid: "4242"),                                     // the pid as a String
            window(omit: ["kCGWindowBounds"]),                       // no rectangle
            window(bounds: "not a rectangle"),                       // the rectangle is not a dictionary
            window(bounds: [String: Any]()),                         // an empty rectangle
            window(bounds: ["X": 0, "Y": 0, "Width": 100]),          // no Height
            window(bounds: ["X": 0, "Y": 0, "Width": Double.nan, "Height": 100]),
            window(bounds: ["X": 0, "Y": 0, "Width": 100, "Height": Double.infinity]),
            window(omit: ["kCGWindowNumber"]),                       // no id to point a capture at
            window(number: "7"),                                     // the id as a String
            window(number: -1),                                      // a negative id
            window(number: 4_294_967_296),                           // UInt32.max + 1
        ]
        let good = window(number: 424_242)
        let got = WindowOrder.recent(hostile + [good], regularPIDs: regularPIDs)
        XCTAssertEqual(got.map(\.windowID), [424_242],
                       "\(hostile.count) hostile dictionaries, each dropped, no trap")
    }

    /// §2A: the same numbers arrive as `Int` from `JSONSerialization` and as bridgeable `NSNumber`
    /// values from CoreGraphics, so a `0.0` layer is layer 0 and a fractional width is a width.
    /// A non-integral layer, pid or id is not silently truncated into a match.
    func testDoubleShapedNumbersAreAcceptedLikeTheIntShapedOnes() {
        let bridged = window(layer: 0.0, pid: 4242.0, number: 77.0,
                             bounds: ["X": -10.0, "Y": 20.0, "Width": 100.5, "Height": 60.25])
        let got = WindowOrder.recent([bridged], regularPIDs: regularPIDs)
        XCTAssertEqual(got, [
            OrderedWindow(windowID: 77, pid: 4242, app: "Notes", title: "Todo",
                          bounds: CGRectCompat(x: -10, y: 20, width: 100.5, height: 60.25)),
        ])

        XCTAssertTrue(WindowOrder.recent([window(number: 1.5)], regularPIDs: regularPIDs).isEmpty)
        XCTAssertTrue(WindowOrder.recent([window(pid: 4242.5)], regularPIDs: regularPIDs).isEmpty)
    }

    /// §2A rule 8: the output order is the input order. Window ids descend, pids interleave
    /// high/low and the app names are out of alphabetical order, so sorting by any of the three
    /// would produce a different list — and one app appears three times, so nothing dedups by pid.
    func testOrderIsLiterallyTheInputOrder() {
        let input = [
            window(pid: 700, owner: "Zebra", name: "z1", number: 14),
            window(pid: 300, owner: "Alpha", name: "a1", number: 13),
            window(pid: 700, owner: "Zebra", name: "z2", number: 12),
            window(pid: 300, owner: "Alpha", name: "a2", number: 11),
            window(pid: 700, owner: "Zebra", name: "z3", number: 10),
        ]
        let got = WindowOrder.recent(input, regularPIDs: [300, 700])
        XCTAssertEqual(got.map(\.windowID), [14, 13, 12, 11, 10], "not sorted by id")
        XCTAssertEqual(got.map(\.pid), [700, 300, 700, 300, 700], "not sorted by pid")
        XCTAssertEqual(got.map(\.app), ["Zebra", "Alpha", "Zebra", "Alpha", "Zebra"], "not sorted by app")
        XCTAssertEqual(got.map(\.title), ["z1", "a1", "z2", "a2", "z3"])
    }

    /// The frozen constants, and §2A rule 7: a regular pid whose owner name is missing still gets a
    /// card with `app == ""`. The pid said it is a real window; the name is cosmetic.
    func testSystemOwnersAndTheEmptyAppFallback() {
        XCTAssertEqual(WindowOrder.systemOwners,
                       ["WindowManager", "Dock", "Window Server", "Control Center", "Notification Center"])

        let noName = window(omit: ["kCGWindowOwnerName"])
        let got = WindowOrder.recent([noName], regularPIDs: regularPIDs)
        XCTAssertEqual(got.map(\.windowID), [7], "kept, not dropped")
        XCTAssertEqual(got.map(\.app), [""])

        XCTAssertEqual(WindowOrder.recent([window(owner: 42)], regularPIDs: regularPIDs).map(\.app), [""],
                       "a non-String owner name reads as \"\"")
        XCTAssertTrue(WindowOrder.recent([window(owner: "Dock")], regularPIDs: regularPIDs).isEmpty,
                      "a system owner never becomes a card, whatever the pid set says")
    }
}
