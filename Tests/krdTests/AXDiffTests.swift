import CoreGraphics
import XCTest
@testable import krd
@testable import krdcore

/// The diff is the half of `tree --diff` that decides *what happened*: which node appeared,
/// which one vanished, which one merely got a new number. All of it is pure (strings in, strings
/// out), so it is tested here rather than against a live app.
final class AXDiffTests: XCTestCase {
    private func step(_ index: Int, _ role: String = "AXButton", id: String = "",
                      title: String = "") -> AXStep {
        AXStep(index: index, role: role, identifier: id, title: title)
    }

    /// The window every chain starts at. Identical in both dumps on purpose: the window is the
    /// thing that did not move, so a test that reports it changed is a test about a bug.
    private var window: AXStep { step(-1, "AXWindow", title: "Doc") }

    private func node(_ ref: String, _ chain: [AXStep], name: String = "", detail: String = "",
                      actions: [String] = [], frame: String = "") -> AXDiffNode {
        AXDiffNode(ref: ref, chain: chain, name: name, detail: detail, actions: actions,
                   frame: frame, detailKnown: true)
    }

    private func change(_ kind: AXDiffKind, _ ref: String) -> AXDiffChange {
        AXDiffChange(kind: kind, ref: ref, previousRef: nil, role: "AXButton", name: "",
                     after: "", before: "")
    }

    // MARK: - nothing happened

    func testAnIdenticalDumpIsEmpty() {
        let previous = [
            node("@e1", [window]),
            node("@e2", [window, step(0, title: "Save")], name: "Save", actions: ["press"]),
        ]
        // The second dump prints the same tree under new numbers: the window is still a dump.
        let current = [
            node("@e10", [window]),
            node("@e11", [window, step(0, title: "Save")], name: "Save", actions: ["press"]),
        ]
        let report = AXDiff.plan(previous: previous, current: current)

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.added.count, 0)
        XCTAssertEqual(report.removed.count, 0)
        XCTAssertEqual(report.changed.count, 0)
        XCTAssertEqual(report.previousCount, 2)
        XCTAssertEqual(report.currentCount, 2)
        // Both nodes kept their place and lost their number: two anchors, no changes.
        XCTAssertEqual(report.anchors.count, 2)

        XCTAssertEqual(AXDiff.unchanged, "unchanged")
        // With nothing to report the summary *is* the one word, generation or not.
        XCTAssertEqual(AXDiff.summary(report, generation: "8f2c1a4e77aa", baseline: "1a2b3c4d"),
                       "unchanged")
    }

    // MARK: - identity, not position

    func testAnInsertedSiblingDoesNotDisturbItsNeighbours() {
        let row = step(0, "AXGroup", title: "row")
        let previous = [
            node("@e1", [window]),
            node("@e2", [window, row, step(0, title: "Save")], name: "Save", actions: ["press"]),
            node("@e3", [window, row, step(1, title: "Cancel")], name: "Cancel",
                 actions: ["press"]),
        ]
        // A text field is inserted in front of the two buttons, so every index after it shifts
        // by one. An index-keyed planner reports the entire row as removed and rebuilt here.
        let current = [
            node("@e10", [window]),
            node("@e11", [window, row, step(0, "AXTextField", title: "Search")], name: "Search"),
            node("@e12", [window, row, step(1, title: "Save")], name: "Save", actions: ["press"]),
            node("@e13", [window, row, step(2, title: "Cancel")], name: "Cancel",
                 actions: ["press"]),
        ]
        let report = AXDiff.plan(previous: previous, current: current)

        XCTAssertTrue(report.changed.isEmpty, "the neighbours moved, they did not change")
        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertEqual(report.added.map(\.name), ["Search"])
        XCTAssertEqual(AXDiff.line(report.added[0]), "+ @e11  textfield  \"Search\"")
        XCTAssertEqual(report.anchors.map(\.ref), ["@e10", "@e12", "@e13"])
        XCTAssertEqual(report.anchors.map(\.previousRef), ["@e1", "@e2", "@e3"] as [String?])
    }

    func testRemovingOneOfTwoIdenticalButtonsIsOneRemovalNotASwap() {
        let previous = [
            node("@e1", [window]),
            node("@e2", [window, step(0, title: "Delete")], name: "Delete", actions: ["press"]),
            node("@e3", [window, step(1, title: "Delete")], name: "Delete", actions: ["press"]),
        ]
        let current = [
            node("@e10", [window]),
            node("@e11", [window, step(0, title: "Delete")], name: "Delete", actions: ["press"]),
        ]
        let report = AXDiff.plan(previous: previous, current: current)

        // One button went away. A planner that matched by ref would instead report two changes:
        // the old @e2 as removed and @e11 as added.
        XCTAssertEqual(report.removed.count, 1)
        XCTAssertEqual(report.removed[0].kind, .removed)
        XCTAssertEqual(report.removed[0].ref, "@e3")
        XCTAssertNil(report.removed[0].previousRef)
        XCTAssertEqual(AXDiff.line(report.removed[0]), "- @e3  button  \"Delete\"  press")
        XCTAssertTrue(report.added.isEmpty)
        XCTAssertTrue(report.changed.isEmpty)
        // The survivor is the same node under a new number.
        XCTAssertEqual(report.anchors.map(\.ref), ["@e10", "@e11"])
        XCTAssertEqual(report.anchors.map(\.previousRef), ["@e1", "@e2"] as [String?])
    }

    // MARK: - what counts as changed

    func testAValueChangeIsOneChangedLineWithBothValues() {
        let search = step(0, "AXTextField", title: "Search")
        let previous = [node("@e137", [window, search], name: "Search", detail: "value=\"\"")]
        let current = [node("@e137", [window, search], name: "Search", detail: "value=\"krd\"")]
        let report = AXDiff.plan(previous: previous, current: current)

        XCTAssertEqual(report.changed.count, 1)
        XCTAssertTrue(report.added.isEmpty)
        XCTAssertTrue(report.removed.isEmpty)
        let changed = report.changed[0]
        XCTAssertEqual(changed.kind, .changed)
        XCTAssertEqual(changed.ref, "@e137")
        XCTAssertEqual(changed.previousRef, "@e137")
        XCTAssertEqual(changed.role, "AXTextField")
        XCTAssertEqual(changed.name, "Search")
        XCTAssertTrue(changed.before.contains("value=\"\""), changed.before)
        XCTAssertTrue(changed.after.contains("value=\"krd\""), changed.after)
        XCTAssertEqual(AXDiff.line(changed),
                       "~ @e137  textfield  \"Search\"  value=\"\" -> \"krd\"")
    }

    func testAnIdentifierKeepsANodeAliveAcrossARetitle() {
        let previous = [
            node("@e1", [window]),
            node("@e5", [window, step(0, id: "playButton", title: "Start")], name: "Start",
                 actions: ["press"]),
        ]
        let current = [
            node("@e8", [window]),
            node("@e9", [window, step(0, id: "playButton", title: "Stop")], name: "Stop",
                 actions: ["press"]),
        ]
        let report = AXDiff.plan(previous: previous, current: current)

        XCTAssertTrue(report.added.isEmpty)
        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertEqual(report.changed.count, 1)
        XCTAssertEqual(report.changed[0].previousRef, "@e5")
        XCTAssertEqual(report.changed[0].ref, "@e9")
        XCTAssertEqual(AXDiff.line(report.changed[0]),
                       "~ @e9  button  \"Start\" -> \"Stop\"  press")
    }

    func testWithoutAnIdentifierARetitleIsARemovalAndAnAddition() {
        let previous = [node("@e5", [window, step(0, title: "Save")], name: "Save")]
        let current = [node("@e9", [window, step(0, title: "Save As…")], name: "Save As…")]
        let report = AXDiff.plan(previous: previous, current: current)

        // The title is all this node had to be known by, so a new title is a new node -- the
        // same answer `AXStep.matches` gives a stale ref.
        XCTAssertTrue(report.changed.isEmpty)
        XCTAssertEqual(report.removed.map(\.ref), ["@e5"])
        XCTAssertEqual(report.added.map(\.ref), ["@e9"])
        XCTAssertTrue(report.anchors.isEmpty)
    }

    // MARK: - anchors

    func testAnchorsCarryThePreviousRef() {
        let email = [window, step(0, "AXTextField", title: "Email")]
        let previous = [node("@e42", email, name: "Email")]
        let current = [node("@e180", email, name: "Email")]
        let report = AXDiff.plan(previous: previous, current: current)

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.anchors.count, 1)
        let anchor = report.anchors[0]
        XCTAssertEqual(anchor.kind, .anchor, "nothing changed, so this is not a change")
        XCTAssertEqual(anchor.ref, "@e180")
        XCTAssertEqual(anchor.previousRef, "@e42")
        XCTAssertEqual(anchor.role, "AXTextField")
        XCTAssertEqual(anchor.name, "Email")
        XCTAssertEqual(AXDiff.line(anchor), "≡ @e180 ≡ @e42  textfield  \"Email\"")
        // The cap is the printer's job; these are the numbers it reads, and they are frozen.
        XCTAssertEqual(AXDiff.anchorLimit, 3)
        XCTAssertEqual(AXDiff.changeLimit, 40)
    }

    // MARK: - purity

    func testThePlannerIsPureAndTwiceTheSame() {
        let row = step(0, "AXGroup", title: "row")
        let previous = [
            node("@e1", [window]),
            node("@e2", [window, row, step(0, title: "Save")], name: "Save", actions: ["press"]),
            node("@e3", [window, row, step(1, title: "Delete")], name: "Delete",
                 actions: ["press"]),
            node("@e4", [window, row, step(2, title: "Delete")], name: "Delete",
                 actions: ["press"]),
            node("@e5", [window, row, step(3, "AXTextField", title: "Search")], name: "Search",
                 detail: "value=\"\""),
        ]
        // A field is inserted, a duplicate button goes away, a value is typed, the rest moves.
        let current = [
            node("@e20", [window]),
            node("@e21", [window, row, step(0, "AXTextField", title: "Filter")], name: "Filter"),
            node("@e22", [window, row, step(1, title: "Save")], name: "Save", actions: ["press"]),
            node("@e23", [window, row, step(2, title: "Delete")], name: "Delete",
                 actions: ["press"]),
            node("@e24", [window, row, step(3, "AXTextField", title: "Search")], name: "Search",
                 detail: "value=\"krd\""),
        ]

        let first = AXDiff.plan(previous: previous, current: current)
        // All four kinds in one report, so the assertion below covers every path.
        XCTAssertEqual(first.added.map(\.ref), ["@e21"])
        XCTAssertEqual(first.removed.map(\.ref), ["@e4"])
        XCTAssertEqual(first.changed.map(\.ref), ["@e24"])
        XCTAssertEqual(first.anchors.map(\.ref), ["@e20", "@e22", "@e23"])
        XCTAssertEqual(first.previousCount, 5)
        XCTAssertEqual(first.currentCount, 5)

        // Same inputs, same report -- and a comparison the other way round in between does not
        // leave anything behind, because nothing is cached on the nodes themselves.
        _ = AXDiff.plan(previous: current, current: previous)
        XCTAssertEqual(AXDiff.plan(previous: previous, current: current), first)
    }

    // MARK: - snapshots

    func testALiveEntryBecomesADiffNodeWithItsPrintedFrame() {
        let entry = AXEntry(
            node: AXNode(ref: "@e7", depth: 2, role: "AXButton", name: "Save", detail: "id=save",
                         frame: CGRect(x: 120, y: 80, width: 64, height: 24), actions: ["press"]),
            chain: [window, step(0, title: "Save")], identifier: "save",
            rawValue: "", rawTitle: "Save")
        let node = AXDiffNode(entry)

        XCTAssertEqual(node.ref, "@e7")
        XCTAssertEqual(node.chain, entry.chain)
        XCTAssertEqual(node.role, "AXButton")
        XCTAssertEqual(node.name, "Save")
        XCTAssertEqual(node.detail, "id=save")
        XCTAssertEqual(node.actions, ["press"])
        XCTAssertEqual(node.frame, "[120,80 64x24]")
        XCTAssertEqual(node.frame, AXText.frameText(entry.node.frame))
        XCTAssertTrue(node.detailKnown)
    }

    func testASchemaTwoSnapshotNodeCarriesThePrintedFields() {
        let stored = AXSnapshotNode(ref: "@e4", chain: [window], root: .window,
                                    name: "Search", detail: "value=\"krd\"", actions: ["press"],
                                    frame: AXFrame(x: 120, y: 80, w: 64, h: 24))
        let node = AXDiffNode(stored)

        XCTAssertEqual(node.ref, "@e4")
        XCTAssertEqual(node.name, "Search")
        XCTAssertEqual(node.detail, "value=\"krd\"")
        XCTAssertEqual(node.actions, ["press"])
        XCTAssertEqual(node.frame, "[120,80 64x24]")
        XCTAssertTrue(node.detailKnown)
    }

    func testAV1SnapshotNodeDiffsStructureOnly() {
        // A v1 dump stored the chain and nothing else: no name, no value, no frame.
        let stored = AXSnapshotNode(ref: "@e3", chain: [window, step(0, title: "Save")],
                                    root: .window)
        let node = AXDiffNode(stored)

        XCTAssertEqual(node.name, "")
        XCTAssertEqual(node.detail, "")
        XCTAssertEqual(node.actions, [])
        XCTAssertEqual(node.frame, "")
        XCTAssertFalse(node.detailKnown, "unknown is not the same as known-empty")

        // Two v1 nodes are matched by their chain, and their re-numbering is an anchor.
        let again = AXDiffNode(AXSnapshotNode(ref: "@e9", chain: stored.chain, root: .window))
        let report = AXDiff.plan(previous: [node], current: [again])
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.anchors.count, 1)
        XCTAssertEqual(report.anchors[0].previousRef, "@e3")
        XCTAssertEqual(report.anchors[0].ref, "@e9")
    }

    func testAV1BaselineIsNotEveryNodeChanged() {
        let text = step(0, "AXTextField", title: "Search")
        let stored = AXSnapshotNode(ref: "@e3", chain: [window, text], root: .window)
        let live = node("@e21", [window, text], name: "Search", detail: "value=\"krd\"",
                        actions: ["press"], frame: "[10,10 40x20]")

        // The baseline knows the node but not what it looked like. Comparing the fields would
        // report a `~` line for every node of the tree; the pair is compared by structure.
        let report = AXDiff.plan(previous: [AXDiffNode(stored)], current: [live])
        XCTAssertTrue(report.changed.isEmpty)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.anchors.count, 1)
        XCTAssertEqual(report.anchors[0].previousRef, "@e3")

        // A schema-2 baseline does know them, so a value that moved is a change again.
        let known = AXDiffNode(AXSnapshotNode(
            ref: "@e40", chain: live.chain, root: .window, name: "Search",
            detail: "value=\"\"", actions: ["press"], frame: AXFrame(x: 10, y: 10, w: 40, h: 20)))
        let second = AXDiff.plan(previous: [known], current: [live])
        XCTAssertEqual(second.changed.count, 1)
        XCTAssertEqual(second.changed[0].kind, .changed)
        XCTAssertEqual(second.changed[0].previousRef, "@e40")
        XCTAssertEqual(AXDiff.line(second.changed[0]),
                       "~ @e21  textfield  \"Search\"  value=\"\" -> \"krd\"  [10,10 40x20]  press")
    }

    // MARK: - the two printed shapes

    func testTheSummaryLineOmitsZeroCountsAndShortensTheGeneration() {
        let report = AXDiffReport(
            added: [change(.added, "@e1"), change(.added, "@e2"), change(.added, "@e3")],
            removed: [change(.removed, "@e4")], changed: [change(.changed, "@e5")],
            anchors: [], previousCount: 134, currentCount: 137)
        XCTAssertEqual(AXDiff.summary(report, generation: "8f2c1a4e77aa", baseline: nil),
                       "3 added, 1 removed, 1 changed · 134 -> 137 nodes · generation 8f2c1a4e")
        XCTAssertEqual(AXDiff.summary(report, generation: nil, baseline: nil),
                       "3 added, 1 removed, 1 changed · 134 -> 137 nodes")
        // No generation of its own: a reader still gets told which dump this is.
        XCTAssertEqual(AXDiff.summary(report, generation: nil, baseline: "1a2b3c4dff"),
                       "3 added, 1 removed, 1 changed · 134 -> 137 nodes · generation 1a2b3c4d")

        let addedOnly = AXDiffReport(added: [change(.added, "@e9")], removed: [], changed: [],
                                     anchors: [], previousCount: 5, currentCount: 6)
        XCTAssertEqual(AXDiff.summary(addedOnly, generation: "aabbccdd", baseline: "00112233"),
                       "1 added · 5 -> 6 nodes · generation aabbccdd")
    }

    func testTheJSONMemberCarriesOnlyWhatTheLineHas() {
        let added = AXDiffChange(kind: .added, ref: "@e5", previousRef: nil, role: "AXButton",
                                 name: "Save", after: "@e5  button  \"Save\"  press", before: "")
        let json = AXDiff.dictionary(added)

        XCTAssertEqual(json["kind"] as? String, "added")
        XCTAssertEqual(json["ref"] as? String, "@e5")
        XCTAssertEqual(json["role"] as? String, "AXButton")
        XCTAssertEqual(json["name"] as? String, "Save")
        XCTAssertEqual(json["after"] as? String, "@e5  button  \"Save\"  press")
        XCTAssertNil(json["previousRef"], "a first-time node has no previous ref to name")
        XCTAssertNil(json["before"], "an added node has no `before` line")
        XCTAssertTrue(json.values.allSatisfy { $0 is String }, "absent, never NSNull")
        XCTAssertFalse(json.values.contains { $0 is NSNull })

        let anchor = AXDiffChange(kind: .anchor, ref: "@e180", previousRef: "@e42",
                                  role: "AXTextField", name: "Email",
                                  after: "@e180  textfield  \"Email\"",
                                  before: "@e42  textfield  \"Email\"")
        let anchorJSON = AXDiff.dictionary(anchor)
        XCTAssertEqual(anchorJSON["kind"] as? String, "anchor")
        XCTAssertEqual(anchorJSON["previousRef"] as? String, "@e42")
        XCTAssertEqual(anchorJSON["before"] as? String, "@e42  textfield  \"Email\"")
        XCTAssertEqual(anchorJSON["after"] as? String, "@e180  textfield  \"Email\"")
    }
}
