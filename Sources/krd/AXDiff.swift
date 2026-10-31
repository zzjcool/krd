// The diff half of `krd ax tree --diff`: what two dumps of one window disagree about.
//
// The only subtle part is identity, and it is worth stating why neither of the two obvious
// handles works. A **ref** cannot identify a node across dumps: refs are monotonic per window
// (AXIndex.counters), so the next dump prints @e134 where this one printed @e1, and the older
// refs it does not reprint still mean what they meant -- a diff keyed on refs would report the
// whole tree as removed and added. A **position** cannot either: inserting one row shifts every
// index below it, and an index-keyed diff then reports the rest of the list as gone and rebuilt.
//
// So a node is matched by its *identity path* from the root. Each step of the chain contributes
// role + (identifier when the app gives one, else title) -- the same rule `AXStep.matches` walks
// a ref with, applied to the whole chain -- and siblings sharing that identity are told apart by
// how many identical ones came before them ("Delete", "Delete"). Inserting a sibling therefore
// renumbers nothing, and two duplicate buttons stay two nodes rather than one that changed.
//
// Everything here is strings and arrays: no AXUIElement, no store, no printing, no clock. The
// caller walks once, hands us the two node lists, and prints what comes back, so
// Tests/krdTests/AXDiffTests.swift covers all of it without an accessibility grant or a screen.

struct AXDiffNode: Equatable {
    var ref: String
    var chain: [AXStep]
    var name: String
    /// The printed `value="…"` / `id=…`, "" when the node printed neither.
    var detail: String
    /// The short actions the dump printed ("press", …).
    var actions: [String]
    /// The printed `[x,y wxh]`, "" when the node had no frame.
    var frame: String
    /// `false` for a v1 snapshot node, which carries none of name/detail/actions/frame. When
    /// either side of a comparison is unknown the planner compares structure only, otherwise
    /// every node of a v1 baseline would read as changed.
    var detailKnown: Bool

    init(ref: String, chain: [AXStep], name: String, detail: String, actions: [String],
         frame: String, detailKnown: Bool) {
        self.ref = ref
        self.chain = chain
        self.name = name
        self.detail = detail
        self.actions = actions
        self.frame = frame
        self.detailKnown = detailKnown
    }

    /// From the live walk's entry (`AXEntry.node` + `AXEntry.chain`).
    ///
    /// The frame is taken through `AXText.frameText` rather than stored as a `CGRect`: the diff
    /// is about what a reader can see, and half a point of movement is not something they can.
    init(_ entry: AXEntry) {
        self.init(ref: entry.node.ref, chain: entry.chain, name: entry.node.name,
                  detail: entry.node.detail, actions: entry.node.actions,
                  frame: AXText.frameText(entry.node.frame), detailKnown: true)
    }

    /// From a stored snapshot node: a v1 node carries no name/detail/actions/frame, so those
    /// come back empty and the node diffs structure only (`detailKnown` is what the planner
    /// reads to know that "" means "not stored" rather than "the dump printed nothing").
    init(_ node: AXSnapshotNode) {
        self.init(ref: node.ref, chain: node.chain, name: node.name ?? "",
                  detail: node.detail ?? "", actions: node.actions ?? [],
                  frame: node.frame?.text ?? "", detailKnown: node.name != nil)
    }
}

extension AXDiffNode {
    /// The full AX role the chain ends at ("AXButton"), "" when the chain is empty.
    var role: String { chain.last?.role ?? "" }
}

enum AXDiffKind: String {
    case added
    case removed
    case changed
    /// Never marks a change: it marks an `anchors` entry, the node that kept its place under a
    /// new ref, which `line()` prints with `≡`.
    case anchor
}

struct AXDiffChange: Equatable {
    var kind: AXDiffKind
    /// Added/changed: the current dump's ref. Removed: the old ref. Anchor: the current ref.
    var ref: String
    /// The ref the previous dump printed for the same node.
    var previousRef: String?
    /// Full AX role ("AXButton"), "" when unknown.
    var role: String
    var name: String
    /// The line this dump prints for the node (added/changed/anchor).
    var after: String
    /// The line the previous dump printed (removed/changed/anchor).
    var before: String
}

struct AXDiffReport: Equatable {
    var added: [AXDiffChange]
    var removed: [AXDiffChange]
    var changed: [AXDiffChange]
    /// Nodes the two dumps agree on, whose ref changed anyway (refs are monotonic per window).
    /// This is the line no other tool prints: "@e180 is the @e42 you pressed".
    var anchors: [AXDiffChange]   // every entry has kind == .anchor and a previousRef
    var previousCount: Int
    var currentCount: Int

    /// Whether anything happened. Anchors are not changes: a node that only got a new number is
    /// still the node the caller was looking at, and a dump with nothing else to say prints one
    /// word (`AXDiff.unchanged`).
    var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
}

enum AXDiff {
    /// How many `≡` lines a text report prints before it says "+N more". The planner does not
    /// cap anything -- it cannot, a report is data -- so the printer reads these.
    static let anchorLimit = 3
    /// How many change lines a text report prints before it says "+N more".
    static let changeLimit = 40
    /// The one word a report with no changes prints, and nothing else.
    static let unchanged = "unchanged"

    /// Pure. Matches nodes by **chain identity**, never by ref and never by position.
    ///
    /// Order is the order a reader would see the tree in: added and changed in the current
    /// dump's walk order, removed in the previous dump's, anchors last in the current one's.
    static func plan(previous: [AXDiffNode], current: [AXDiffNode]) -> AXDiffReport {
        let previousKeys = matchKeys(previous)
        let currentKeys = matchKeys(current)

        // Keys are unique within one dump (the ordinal separates duplicate siblings), so a
        // dictionary is a lookup, not a guess.
        var previousByKey: [String: AXDiffNode] = [:]
        for (index, key) in previousKeys.enumerated() where previousByKey[key] == nil {
            previousByKey[key] = previous[index]
        }

        var added: [AXDiffChange] = []
        var changed: [AXDiffChange] = []
        var anchors: [AXDiffChange] = []
        var matched = Set<String>()
        for (index, key) in currentKeys.enumerated() {
            let node = current[index]
            guard let old = previousByKey[key] else {
                added.append(AXDiffChange(kind: .added, ref: node.ref, previousRef: nil,
                                          role: node.role, name: node.name,
                                          after: render(node), before: ""))
                continue
            }
            matched.insert(key)
            if agrees(old, node) {
                // The same node under a new number: this is the line that lets a caller carry
                // `press @e42` across a re-dump without re-reading the tree.
                if old.ref != node.ref {
                    anchors.append(AXDiffChange(kind: .anchor, ref: node.ref,
                                                previousRef: old.ref, role: node.role,
                                                name: node.name, after: render(node),
                                                before: render(old)))
                }
            } else {
                changed.append(AXDiffChange(kind: .changed, ref: node.ref,
                                            previousRef: old.ref, role: node.role,
                                            name: node.name, after: render(node),
                                            before: render(old)))
            }
        }

        var removed: [AXDiffChange] = []
        for (index, key) in previousKeys.enumerated() where !matched.contains(key) {
            let node = previous[index]
            removed.append(AXDiffChange(kind: .removed, ref: node.ref, previousRef: nil,
                                        role: node.role, name: node.name, after: "",
                                        before: render(node)))
        }

        return AXDiffReport(added: added, removed: removed, changed: changed, anchors: anchors,
                            previousCount: previous.count, currentCount: current.count)
    }

    /// The summary line: "3 added, 1 removed, 1 changed · 134 -> 137 nodes · generation 8f2c1a4e".
    ///
    /// Zero counts are left out rather than printed as "0 removed": the point of the line is what
    /// happened. A report with nothing in it says `unchanged` and stops, because that is the
    /// whole output of such a dump.
    ///
    /// `generation` is the dump this report is about; `baseline` is only a fallback for the case
    /// where it has no generation of its own, so a reader is never handed a bare "134 -> 137".
    static func summary(_ report: AXDiffReport, generation: String?, baseline: String?) -> String {
        guard !report.isEmpty else { return unchanged }
        var counts: [String] = []
        if !report.added.isEmpty { counts.append("\(report.added.count) added") }
        if !report.removed.isEmpty { counts.append("\(report.removed.count) removed") }
        if !report.changed.isEmpty { counts.append("\(report.changed.count) changed") }
        var parts: [String] = [counts.joined(separator: ", ")]
        parts.append("\(report.previousCount) -> \(report.currentCount) nodes")
        if let label = short(generation) ?? short(baseline) {
            parts.append("generation \(label)")
        }
        return parts.joined(separator: " · ")
    }

    /// Eight characters are enough to name a dump in one line; the full id is in `--json`.
    private static func short(_ generation: String?) -> String? {
        guard let generation, !generation.isEmpty else { return nil }
        return String(generation.prefix(8))
    }

    /// One `+`/`-`/`~`/`≡` line, `AXText.render`-shaped after the marker.
    ///
    /// The text of a node is decided when the report is planned (`before`/`after` carry the
    /// dump's own rendering); this only prefixes the marker, and for `~` merges the two
    /// renderings into one line so the change is the thing that stands out:
    ///
    ///     ~ @e137  textfield  "Search"  value="" -> "krd"
    ///     ≡ @e180 ≡ @e42  textfield  "Email"
    ///
    /// No depth indentation: a report only carries nodes that moved, so an indent would say
    /// "two levels down" about a node whose parent is not on screen.
    static func line(_ change: AXDiffChange) -> String {
        switch change.kind {
        case .added:
            return "+ " + change.after
        case .removed:
            return "- " + change.before
        case .changed:
            let body = merged(before: body(change.before), after: body(change.after))
            return body.isEmpty ? "~ \(change.ref)" : "~ \(change.ref)\(separator)\(body)"
        case .anchor:
            let previous = change.previousRef ?? ""
            let rest = body(change.after)
            let head = "≡ \(change.ref) ≡ \(previous)"
            return rest.isEmpty ? head : head + separator + rest
        }
    }

    /// The `--json` member of one change: kind, ref, previousRef?, role, name, before?, after?.
    ///
    /// Absent fields are absent keys, never `NSNull`: a reader that tests for the key must not
    /// have to tell "no previous ref" from "the JSON encoder could not say".
    static func dictionary(_ change: AXDiffChange) -> [String: Any] {
        var out: [String: Any] = [
            "kind": change.kind.rawValue, "ref": change.ref,
            "role": change.role, "name": change.name,
        ]
        if let previousRef = change.previousRef { out["previousRef"] = previousRef }
        if !change.before.isEmpty { out["before"] = change.before }
        if !change.after.isEmpty { out["after"] = change.after }
        return out
    }

    // MARK: - identity

    /// What one step contributes to a node's identity: the role, plus the identifier when the
    /// app gives one -- it is the only handle an app promises to keep, so a button whose title
    /// flips "Start"/"Stop" is still the same button -- and the title otherwise.
    ///
    /// This is the rule `AXStep.matches` applies, so "the same node" means the same thing to a
    /// ref lookup and to a diff. The separator is a C0 character (which `AXText.sanitize` strips
    /// from everything the dump prints) so a role, title and identifier cannot run into one
    /// another by accident.
    private static func identity(_ step: AXStep) -> String {
        step.role + "\u{1}" + (step.identifier.isEmpty ? step.title : step.identifier)
    }

    /// The key of every node in `nodes`: `parent|identity#n`, root first, where `n` counts the
    /// earlier siblings with the same identity under the same parent.
    private static func matchKeys(_ nodes: [AXDiffNode]) -> [String] {
        var tree = IdentityTree()
        for (index, node) in nodes.enumerated() {
            tree.insert(node.chain.map(identity), leaf: index)
        }
        return tree.keys(count: nodes.count)
    }

    /// Does a matched pair describe the same node?
    ///
    /// A v1 baseline stored nothing but the chain, so comparing name/detail/actions/frame would
    /// report every node of it as changed; such a pair is compared by structure (its key) alone.
    private static func agrees(_ old: AXDiffNode, _ new: AXDiffNode) -> Bool {
        guard old.detailKnown, new.detailKnown else { return true }
        return old.name == new.name && old.detail == new.detail
            && old.actions == new.actions && old.frame == new.frame
    }

    /// The identity tree one dump's chains describe.
    ///
    /// The chains are a tree already, but only by their *identities*: two duplicate "Delete"
    /// buttons have chains that differ in nothing but `index`, so they land on one level and are
    /// numbered there. That is the whole trick -- the numbering happens per parent, in walk
    /// order, so a node's key never depends on a position in a list.
    private struct IdentityTree {
        private struct Level {
            var ident: String
            var children: [Int] = []
            /// Indices into the caller's node array, in walk order.
            var leaves: [Int] = []
        }

        private var levels: [Level] = [Level(ident: "")]

        mutating func insert(_ identities: [String], leaf: Int) {
            // A chainless node cannot happen from a walk (the window is always the first step),
            // but it still needs a key of its own rather than a crash.
            let path = identities.isEmpty ? [""] : identities
            var level = 0
            for ident in path {
                let children = levels[level].children
                if let child = children.first(where: { levels[$0].ident == ident }) {
                    level = child
                    continue
                }
                levels.append(Level(ident: ident))
                let child = levels.count - 1
                levels[level].children.append(child)
                level = child
            }
            levels[level].leaves.append(leaf)
        }

        func keys(count: Int) -> [String] {
            var out = [String](repeating: "", count: count)
            var stack: [(level: Int, parent: String)] = [(0, "")]
            while let (level, parent) = stack.popLast() {
                var counts: [String: Int] = [:]
                for child in levels[level].children {
                    let ident = levels[child].ident
                    let base = parent.isEmpty ? ident : parent + "|" + ident
                    let first = counts[ident] ?? 0
                    let leaves = levels[child].leaves
                    for (offset, leaf) in leaves.enumerated() where leaf < out.count {
                        out[leaf] = base + "#" + String(first + offset)
                    }
                    counts[ident] = first + leaves.count
                    // Everything under a duplicated sibling hangs off its first number: two
                    // identical parents are indistinguishable by design, so their subtrees share
                    // one key space rather than pretending to a distinction they do not have.
                    stack.append((child, base + "#" + String(first)))
                }
            }
            return out
        }
    }

    // MARK: - rendering

    /// `AXText.render`'s shape, at depth 0: `@e3  button  "Save"  value="hi"  [120,80 64x24]  press`.
    /// Absent fields are omitted, exactly as the tree prints them.
    private static func render(_ node: AXDiffNode) -> String {
        var parts: [String] = [node.ref, AXText.shortRole(node.role)]
        if !node.name.isEmpty { parts.append("\"\(node.name)\"") }
        if !node.detail.isEmpty { parts.append(node.detail) }
        if !node.frame.isEmpty { parts.append(node.frame) }
        if !node.actions.isEmpty { parts.append(node.actions.joined(separator: ",")) }
        return parts.joined(separator: separator)
    }

    private static let separator = "  "

    /// A rendering without its leading ref, which is the field a `~`/`≡` line prints itself.
    private static func body(_ line: String) -> String {
        let parts = fields(line)
        guard parts.count > 1 else { return "" }
        return parts.dropFirst().joined(separator: separator)
    }

    /// One line out of two: the fields both sides agree on are printed once, and the fields that
    /// differ are printed as `before -> after`. A node usually changes one field (its value, or
    /// its frame), and printing the whole line twice would bury the thing that changed.
    ///
    /// The common head and the common tail are both kept, because an optional field sits in the
    /// middle of `name detail frame actions`: a frame that appears shifts nothing to its left but
    /// must not swallow the actions on its right.
    private static func merged(before: String, after: String) -> String {
        let old = fields(before)
        let new = fields(after)
        if old == new { return after }
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let gone = old[head..<(old.count - tail)].joined(separator: separator)
        let came = new[head..<(new.count - tail)].joined(separator: separator)
        var parts = Array(old[0..<head])
        // A field that only one side has (a value that appeared, a frame that went away) is
        // printed on its own: "-> value=\"krd\"" would say the same thing with more noise.
        if gone.isEmpty || came.isEmpty {
            if !came.isEmpty { parts.append(came) } else if !gone.isEmpty { parts.append(gone) }
        } else {
            parts.append(differing(gone, came))
        }
        parts.append(contentsOf: new[(new.count - tail)..<new.count])
        return parts.joined(separator: separator)
    }

    /// Two versions of one field.
    ///
    /// When they share a `name=` prefix the prefix is printed once -- `value="" -> "krd"`
    /// points at what changed, `value="" -> value="krd"` says "value" twice -- which is the
    /// only shape a `value="…"` / `id=…` detail ever takes.
    private static func differing(_ before: String, _ after: String) -> String {
        if let oldKey = before.firstIndex(of: "="), let newKey = after.firstIndex(of: "="),
           before[..<oldKey] == after[..<newKey] {
            let key = before[..<before.index(after: oldKey)]
            // An attribute name, not a slice of prose: letters, digits, underscore, short. That
            // keeps this off a quoted name that happens to contain an `=`.
            let name = key.dropLast()
            if !name.isEmpty, name.count <= 8,
               name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                let old = before[before.index(after: oldKey)...]
                let new = after[after.index(after: newKey)...]
                if old != new { return String(key) + "\(old) -> \(new)" }
            }
        }
        return "\(before) -> \(after)"
    }

    /// Split one rendering into its fields.
    ///
    /// Two spaces separate fields (`AXText.render`), but a name is quoted and may contain any
    /// run of spaces -- including two -- so the splitter has to know when it is inside a quote.
    private static func fields(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        var spaces = 0
        for character in line {
            if character == "\"" { quoted.toggle() }
            if character == " ", !quoted {
                spaces += 1
                continue
            }
            if spaces > 0 {
                if spaces >= 2 {
                    out.append(current)
                    current = ""
                } else {
                    current.append(" ")
                }
                spaces = 0
            }
            current.append(character)
        }
        out.append(current)
        return out
    }
}
