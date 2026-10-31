import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import krd

/// Issue #104: `AXWalker.walk` paid **three** accessibility round trips per node — the batch of
/// seven attributes, `CopyActionNames`, and a separate `CopyAttributeValue` for `AXChildren`.
/// `AXChildren` is an ordinary attribute, so it rides in the batch: **two** round trips per node.
///
/// Why a synthetic tree and not a real one: a round trip costs what it costs only on an element
/// that answers, and this machine answers nothing — `CopyMultipleAttributeValues` returns
/// `err=-25208` (apiDisabled) with every slot nil unless Accessibility is granted, which it is not
/// for this binary, and an AX call on a non-granted element can block. So the *count* is what is
/// measured here, through `AXAccess`: the walk runs its real body over an in-memory tree of
/// `AXUIElement`s (`AXUIElementCreateApplication` on distinct synthetic pids — they are distinct
/// `CFHash` values, distinct elements, and reading them is never attempted because every read goes
/// through the fake).
///
/// What this proves: (1) exactly two reads per visited node, with no node paying three and no leaf
/// paying for a children read it does not need; (2) both paths — children in the batch and the
/// pre-#104 separate read — produce **byte-identical** text and JSON for the same tree, so the
/// change cannot move any node, ref, depth, name, detail or action; (3) the fallback: an element
/// whose batch answers nothing at all still falls back to the separate read, so an app that does
/// not implement multi-value reads does not lose its subtree.
///
/// What this cannot prove: that a *real* app returns children as the 8th batch value. That was
/// measured in the issue (`err=0, n=8`, 0.265 ms vs 0.057 + 0.233 ms for the two calls) and the
/// numbers are quoted at `AXWalker.attributeNames`; no wall clock is quoted here, because no
/// wall clock on this machine would be real.
final class AXWalkRoundTripTests: XCTestCase {

    // MARK: - a tree that is not an accessibility tree

    /// One node of the synthetic tree. Everything the walk reads is here, so a field the walk
    /// starts reading (or stops reading) shows up as a test failure rather than as a silent
    /// extra round trip.
    struct FakeNode {
        enum Children { case list, absent }

        var role: String
        var title: String = ""
        var value: String = ""
        var identifier: String = ""
        var description: String = ""
        var frame: (origin: CGPoint, size: CGSize)?
        var actions: [String] = []
        var children: [Int] = []
        /// A leaf whose `AXChildren` slot the batch answers with a hole instead of an empty
        /// array. Both are leaves; neither may cost a third round trip.
        var childrenSlot: Children = .list

        /// The value a real `CopyAttributeValue(s)` call would answer for `name`. Strings go out
        /// as `NSString` and lists as `NSArray`, i.e. the CF types production casts from.
        func attribute(_ name: String) -> AnyObject? {
            switch name {
            case kAXRoleAttribute as String: return role as NSString
            case kAXTitleAttribute as String: return title as NSString
            case kAXValueAttribute as String: return value as NSString
            case kAXIdentifierAttribute as String: return identifier as NSString
            case kAXDescriptionAttribute as String: return description as NSString
            case kAXPositionAttribute as String:
                guard let frame else { return NSNull() }
                var point = frame.origin
                return AXValueCreate(.cgPoint, &point)
            case kAXSizeAttribute as String:
                guard let frame else { return NSNull() }
                var size = frame.size
                return AXValueCreate(.cgSize, &size)
            default: return nil    // the caller decides: children or a hole
            }
        }
    }

    struct FakeTree {
        var nodes: [FakeNode]
        /// Distinct pids, so `CFHash` (the walk's cycle guard) sees distinct elements.
        var basePid: pid_t = 900_000

        func element(_ index: Int) -> AXUIElement {
            AXUIElementCreateApplication(basePid + pid_t(index))
        }
        var root: AXUIElement { element(0) }
        func index(of element: AXUIElement) -> Int? {
            nodes.indices.first { self.element($0) == element }
        }
        func node(for element: AXUIElement) -> FakeNode? { index(of: element).map { nodes[$0] } }
        func children(of index: Int) -> NSArray {
            nodes[index].children.map { element($0) } as NSArray
        }
        /// Distance from the root in the four-ary tree built by `windowTree`.
        func depth(of index: Int) -> Int {
            var depth = 0
            var node = index
            while node > 0 { node = (node - 1) / 4; depth += 1 }
            return depth
        }
    }

    /// Every accessibility call the walk makes, counted — and counted *per node*, because a mean
    /// of two hides the node that still pays three.
    final class Calls {
        var batch = 0
        var actions = 0
        var value = 0
        var perNode: [Int: Int] = [:]
        /// How many attribute names each node's batch asked for (`--max` depth asks for 7).
        var namesPerNode: [Int: Int] = [:]

        var roundTrips: Int { batch + actions + value }

        /// The most round trips any single node paid.
        var worst: Int { perNode.values.max() ?? 0 }
    }

    private func access(_ tree: FakeTree, _ calls: Calls, carriesChildren: Bool = true,
                        silent: Set<Int> = []) -> AXAccess {
        AXAccess(
            batch: { element, names in
                calls.batch += 1
                guard let index = tree.index(of: element), let node = tree.nodes[safe: index] else {
                    return Array(repeating: nil, count: names.count)
                }
                calls.perNode[index, default: 0] += 1
                calls.namesPerNode[index] = names.count
                // An element whose batch answers nothing at all: an app that does not implement
                // multi-value reads, or a grant that lapsed mid-walk.
                if silent.contains(index) { return Array(repeating: nil, count: names.count) }
                return names.map { name in
                    if name == kAXChildrenAttribute as String {
                        // The pre-#104 batch did not ask for children at all, so it must not
                        // answer them either — otherwise a slot-order or cast mistake would be
                        // shared by both runs and the A/B would prove nothing.
                        guard carriesChildren else { return nil }
                        switch node.childrenSlot {
                        case .list: return tree.children(of: index)
                        case .absent: return NSNull()
                        }
                    }
                    return node.attribute(name)
                }
            },
            actions: { element in
                calls.actions += 1
                if let index = tree.index(of: element) { calls.perNode[index, default: 0] += 1 }
                return tree.node(for: element)?.actions ?? []
            },
            value: { element, name in
                calls.value += 1
                guard let index = tree.index(of: element), let node = tree.nodes[safe: index] else {
                    return nil
                }
                calls.perNode[index, default: 0] += 1
                if name == kAXChildrenAttribute as String {
                    return node.childrenSlot == .list ? tree.children(of: index) : NSNull()
                }
                return node.attribute(name)
            },
            carriesChildren: carriesChildren)
    }

    // MARK: - the tree a 400-node dump has

    /// A four-level window tree, deterministic: window → groups (named and unnamed) → rows /
    /// splitters → interactive leaves (buttons, fields, a long `AXValue`), and `AXCell` below that.
    /// 400 is `krd ax`'s default `--max`, so "per dump" below means the same thing it means there.
    private func windowTree(count: Int = 400) -> FakeTree {
        var nodes: [FakeNode] = [
            FakeNode(role: "AXWindow", title: "Untitled",
                     frame: (CGPoint(x: 0, y: 0), CGSize(width: 1200, height: 800)))
        ]
        for index in 1..<count {
            let parent = (index - 1) / 4
            let depth = index % 4 == 0 ? 3 : (index / 4) % 4
            var node: FakeNode
            switch depth % 5 {
            case 0:
                node = FakeNode(role: "AXGroup", title: index % 2 == 0 ? "Sidebar" : "")
            case 1:
                node = FakeNode(role: index % 3 == 0 ? "AXRow" : "AXSplitter")
            case 2:
                node = FakeNode(role: "AXButton", title: "Action \(index)", actions: ["press"])
            case 3:
                node = FakeNode(role: "AXTextField", title: "Search",
                                value: index % 3 == 0 ? "query \(index)" : "",
                                identifier: "field-\(index)", actions: ["confirm"])
            default:
                node = FakeNode(role: "AXTextArea", value: String(repeating: "body ", count: 40),
                                actions: ["press"])
            }
            node.frame = (CGPoint(x: 8 * (index % 40), y: 6 * (index % 30)),
                          CGSize(width: 64 + index % 200, height: 18 + index % 40))
            nodes.append(node)
            nodes[parent].children.append(index)
        }
        // Every leaf answers `AXChildren` with an empty array, which is what a leaf looks like;
        // the "did not answer at all" case has its own test, because it is the one shape that
        // costs a third round trip.
        return FakeTree(nodes: nodes)
    }

    private func walk(_ tree: FakeTree, _ calls: Calls, carriesChildren: Bool = true,
                      silent: Set<Int> = [], interactiveOnly: Bool = false,
                      maxDepth: Int = 60) -> AXWalker {
        var walker = AXWalker(
            interactiveOnly: interactiveOnly, emitEverything: false, includeMenus: false,
            maxDepth: maxDepth, maxShown: 10_000, maxVisited: 100_000,
            deadline: Date().addingTimeInterval(120),
            access: access(tree, calls, carriesChildren: carriesChildren, silent: silent))
        walker.walk(root: tree.root, rootDepth: 0, countAsRoot: false)
        return walker
    }

    // MARK: - the number the issue asked for

    func testTheWalkPaysTwoRoundTripsPerNodeNotThree() {
        let tree = windowTree()
        let after = Calls()
        let walker = walk(tree, after)
        XCTAssertEqual(walker.visited, tree.nodes.count, "the whole synthetic tree must be walked")

        let before = Calls()
        let legacy = walk(tree, before, carriesChildren: false)
        XCTAssertEqual(legacy.visited, walker.visited)

        // Two, on every node — not "two on average": the batch, and the actions.
        XCTAssertEqual(after.batch, walker.visited, "one batched attribute read per node")
        XCTAssertEqual(after.actions, walker.visited, "one CopyActionNames per node")
        XCTAssertEqual(after.value, 0, "no separate CopyAttributeValue: children rode in the batch")
        XCTAssertEqual(after.worst, 2, "no node pays a third round trip")
        XCTAssertEqual(after.roundTrips, walker.visited * 2)

        // And before: three, because children were a read of their own.
        XCTAssertEqual(before.value, legacy.visited, "the pre-#104 path read children separately")
        XCTAssertEqual(before.roundTrips, legacy.visited * 3)

        print("RT nodes=\(walker.visited) before=\(before.roundTrips) "
            + "(\(Double(before.roundTrips) / Double(legacy.visited)) per node) "
            + "after=\(after.roundTrips) (\(Double(after.roundTrips) / Double(walker.visited)) per node)")

        // Exactly a third fewer, at any tree size.
        XCTAssertEqual(after.roundTrips * 3, before.roundTrips * 2)
    }

    func testALeafCostsTwoRoundTripsAndASilentAttributeCostsWhatItAlwaysDid() {
        // A window whose children are all leaves: ten answer `AXChildren` with an empty array —
        // what a leaf looks like, and two round trips — and ten with a hole, i.e. they did not
        // answer the attribute at all. A hole takes the separate read (a subtree must never be
        // mistaken for nothing) and costs exactly what it cost before #104: three.
        var nodes = [FakeNode(role: "AXWindow", title: "Empty")]
        for index in 1...20 {
            nodes.append(FakeNode(role: "AXButton", title: "B\(index)", actions: ["press"],
                                  childrenSlot: index % 2 == 0 ? .list : .absent))
            nodes[0].children.append(index)
        }
        let tree = FakeTree(nodes: nodes)
        let calls = Calls()
        let walker = walk(tree, calls)

        XCTAssertEqual(walker.visited, 21)
        XCTAssertEqual(calls.value, 10, "one read for each of the ten silent leaves")
        XCTAssertEqual(calls.roundTrips, 21 * 2 + 10)
        XCTAssertEqual(calls.worst, 3, "a silent attribute still costs three, never more")
        // The window and the ten answering leaves: two.
        let answering = [0] + (1...20).filter { $0 % 2 == 0 }
        for index in answering { XCTAssertEqual(calls.perNode[index], 2, "node \(index)") }
    }

    func testANodeAtTheDepthLimitDoesNotAskForChildren() {
        // `--max-depth` cuts the walk where a node's children would be discarded, so the batch
        // must not marshal the array for it: that transfer is 0.2 ms of the 0.265 ms batch.
        // Round trips are two either way — before #104 such a node paid no children read at all.
        let tree = windowTree(count: 200)
        let calls = Calls()
        let walker = walk(tree, calls, maxDepth: 2)
        let limit = 2

        let expected = tree.nodes.indices.filter { tree.depth(of: $0) <= limit }
        XCTAssertEqual(walker.visited, expected.count, "the walk stops at the depth limit")
        XCTAssertEqual(Set(calls.namesPerNode.keys), Set(expected))
        for (index, names) in calls.namesPerNode {
            XCTAssertEqual(names, tree.depth(of: index) >= limit ? 7 : 8,
                           "node \(index) at depth \(tree.depth(of: index)) asked for \(names) names")
        }
        XCTAssertEqual(calls.roundTrips, walker.visited * 2)
        XCTAssertEqual(calls.value, 0, "the depth limit needs no separate children read either")
    }

    // MARK: - the same tree out of both paths

    func testBothPathsPrintOneByteIdenticalTree() {
        let tree = windowTree()
        let fast = walk(tree, Calls())
        let slow = walk(tree, Calls(), carriesChildren: false)

        // Text: every line, in order.
        let text = fast.entries.map { AXText.render($0.node) }
        XCTAssertEqual(text, slow.entries.map { AXText.render($0.node) })
        XCTAssertGreaterThan(fast.entries.count, 200, "the tree must be big enough to mean something")

        // JSON, byte for byte, key order included (`jsonString` sorts keys).
        XCTAssertEqual(json(fast), json(slow))
        XCTAssertTrue(json(fast).hasPrefix("{\"app\":\"Synthetic\""))

        // What `find`, `press` and `set` re-find the node by: the chain, the raw (unsanitized)
        // fields and the identifier. If the batch path dropped any of them, a ref would land on
        // another node.
        XCTAssertEqual(fast.entries.map { $0.chain }, slow.entries.map { $0.chain })
        XCTAssertEqual(fast.entries.map { $0.identifier }, slow.entries.map { $0.identifier })
        XCTAssertEqual(fast.entries.map { $0.rawValue }, slow.entries.map { $0.rawValue })
        XCTAssertEqual(fast.entries.map { $0.rawTitle }, slow.entries.map { $0.rawTitle })
        XCTAssertEqual(fast.entries.map { $0.node.ref }, slow.entries.map { $0.node.ref })
        XCTAssertEqual(fast.entries.map { $0.node.depth }, slow.entries.map { $0.node.depth })
        XCTAssertEqual(fast.entries.map { $0.node.actions }, slow.entries.map { $0.node.actions })
        XCTAssertEqual(fast.entries.map { $0.root }, slow.entries.map { $0.root })

        // Pinned bytes, so "identical" cannot be satisfied by two identically broken paths.
        XCTAssertEqual(text.first, #"@e1  window  "Untitled"  [0,0 1200x800]"#)
        XCTAssertEqual(text[1], #"@e2    group  "Sidebar"  [16,12 66x20]"#)
        XCTAssertEqual(text[2], #"@e3    textfield  "Search"  id=field-4  [32,24 68x22]  confirm"#)
        XCTAssertTrue(text.contains { $0.contains(#"value="query 12""#) },
                      "an AXTextField's value must survive the batch")
        XCTAssertTrue(text.contains { $0.hasSuffix("  textfield  \"Search\"  id=field-8  [64,48 72x26]  confirm") },
                      "a field with no value must fall back to its identifier")
        XCTAssertTrue(text.contains { $0.contains("press") }, "actions must survive the batch")
    }

    private func json(_ walker: AXWalker) -> String {
        AXCommand.jsonString(AXTreeJSON(
            app: "Synthetic", pid: 900_000, windowIndex: 0, windowCount: 1,
            windowTitle: "Untitled", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            nodes: walker.nodes, truncated: walker.truncated, visited: walker.visited,
            generation: "gen-1").dictionary)
    }

    // MARK: - the fallback that keeps a broken app walkable

    func testAnElementWhoseBatchAnswersNothingStillWalksItsSubtree() {
        // Node 1 is a group with children, and its batch comes back all nil — the shape this
        // machine has without a grant (`err=-25208`). Children must still be read the old way,
        // otherwise the whole subtree turns into a leaf.
        let tree = windowTree(count: 60)
        let silent: Set<Int> = [1]
        let fast = walk(tree, Calls(), silent: silent)
        let slow = walk(tree, Calls(), carriesChildren: false, silent: silent)

        XCTAssertEqual(fast.visited, tree.nodes.count, "no subtree was lost to the silent element")
        XCTAssertEqual(fast.entries.map { AXText.render($0.node) },
                       slow.entries.map { AXText.render($0.node) })
        XCTAssertEqual(json(fast), json(slow))

        let calls = Calls()
        let counted = walk(tree, calls, silent: silent)
        XCTAssertEqual(counted.visited, tree.nodes.count)
        XCTAssertEqual(calls.value, 1, "one fallback read, for the one silent element")
        XCTAssertEqual(calls.roundTrips, counted.visited * 2 + 1)
        XCTAssertEqual(calls.perNode[silent.first!], 3, "the silent element paid three, the rest two")
        XCTAssertEqual(calls.roundTrips, counted.visited * 2 + 1,
                       "the fallback is one read, and it went to the one silent element")
    }

    // MARK: - the defaults production runs with

    func testProductionTakesTheBatchPath() {
        // A future edit that flips either of these puts three round trips back in the walk
        // without changing a single test tree, so they are pinned here.
        XCTAssertTrue(AXAccess.system.carriesChildren)
        XCTAssertEqual(AXWalker.attributeNames.count, 8)
        XCTAssertEqual(AXWalker.attributeNames.last, kAXChildrenAttribute as String)
        XCTAssertEqual(AXWalker.attributeNamesAtLimit, Array(AXWalker.attributeNames.dropLast()))
        XCTAssertFalse(AXWalker.attributeNamesAtLimit.contains(kAXChildrenAttribute as String))
        XCTAssertEqual(Array(AXWalker.attributeNames.prefix(7)),
                       [kAXRoleAttribute as String, kAXTitleAttribute as String,
                        kAXValueAttribute as String, kAXIdentifierAttribute as String,
                        kAXPositionAttribute as String, kAXSizeAttribute as String,
                        kAXDescriptionAttribute as String])
    }

    // MARK: - the filter that decides a line, unchanged by any of this

    func testInteractiveOnlyStillWalksEverythingButEmitsLess() {
        // The walk visits the same nodes either way (the budget and the cycle guard depend on it);
        // only the emitted lines shrink. A batch that carried children must not change that.
        let tree = windowTree(count: 200)
        let all = walk(tree, Calls())
        let only = walk(tree, Calls(), interactiveOnly: true)
        XCTAssertEqual(only.visited, all.visited)
        XCTAssertLessThan(only.entries.count, all.entries.count)
        XCTAssertTrue(only.entries.allSatisfy { !$0.node.actions.isEmpty || $0.node.role == "AXWindow"
            || AXText.interactiveRoles.contains($0.node.role) })
    }
}

// MARK: - small helpers

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
