// Refs that outlive the process that printed them, without a daemon.
//
// `krd ax tree` prints `@e7`, and the next invocation has to turn that back into the same
// element. A ref is therefore a *snapshot* plus a *path*: the snapshot is a small JSON file
// under $TMPDIR/keyed by app+window, and the path is the list of children we walked through,
// each carrying what that child looked like at the time (documents/research §8).
//
// The path is verified, not trusted. If a step no longer matches, the ref is stale and the
// command fails with "re-dump" instead of acting on whatever happens to be at that index now:
// a text channel that clicks the wrong button is worse than one that admits it is lost.
//
// Nothing in this file talks to the accessibility API, so it is covered by
// Tests/krdTests/AXRefsTests.swift -- the AX side only supplies "the children of this element".

import Foundation

/// `@e12` -- the handle a dump prints.
struct AXRef: Equatable, Hashable, CustomStringConvertible {
    static let prefix = "@e"
    /// 1-based, exactly as printed (`@e1` is the first node).
    var index: Int

    init(index: Int) { self.index = index }

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(AXRef.prefix) else { return nil }
        let digits = trimmed.dropFirst(AXRef.prefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits), value >= 1 else { return nil }
        index = value
    }

    var description: String { "\(AXRef.prefix)\(index)" }
}

/// One step from a window root to a node: the child index we walked through, plus a summary
/// of the child, so a later process can tell "the same node" from "some node at this index".
struct AXStep: Codable, Equatable {
    /// -1 for the root of a dump (a window), which has no parent to index into.
    var index: Int
    var role: String
    var identifier: String
    var title: String

    /// Do two descriptions of a node agree?
    ///
    /// An `AXIdentifier` is the only handle an app promises to keep, so when both sides have
    /// one it decides on its own -- a button whose title flips "Start"/"Stop" is still the same
    /// button. Without one, role+title is all there is, and a retitled node reads as gone.
    func matches(_ other: AXStep) -> Bool {
        guard role == other.role else { return false }
        if !identifier.isEmpty, !other.identifier.isEmpty { return identifier == other.identifier }
        return title == other.title
    }
}

/// What one level of a chain lookup found.
enum AXDescent: Equatable {
    /// The node is where it was.
    case same(Int)
    /// The node moved, but exactly one child matches its description.
    case moved(Int)
    /// Several children match: guessing would be worse than failing.
    case ambiguous([Int])
    /// Nothing at this level matches: the node is gone, retitled, or the chain is stale.
    case gone
}

enum AXRefs {
    /// Where a single link of the chain lands among `children`.
    ///
    /// The fast path is the recorded index -- trees barely move, and a matching index needs no
    /// search. Only when that fails do we look at every child, and we accept a moved node only
    /// if exactly one child answers to it.
    static func descend(_ step: AXStep, children: [AXStep]) -> AXDescent {
        if step.index >= 0, step.index < children.count, children[step.index].matches(step) {
            return .same(step.index)
        }
        let hits = children.indices.filter { children[$0].matches(step) }
        switch hits.count {
        case 0: return .gone
        case 1: return .moved(hits[0])
        default: return .ambiguous(hits)
        }
    }
}

/// Which element a chain starts from: a `--menubar` dump walks the menu bar and the window
/// into one snapshot, and their chains are not interchangeable.
enum AXRoot: String, Codable {
    case window
    case menuBar
}

/// What one node of a dump looked like, and how to walk back to it.
struct AXSnapshotNode: Codable, Equatable {
    var ref: String
    /// Root … node. The last element is the node itself.
    var chain: [AXStep]
    /// Absent in snapshots written before this field existed; those are window chains.
    var root: AXRoot?
}

/// One `krd ax tree` / `krd ax find` output, written to disk so refs survive the process.
struct AXSnapshot: Codable, Equatable {
    static let schema = 1

    var schema: Int
    /// Random per dump; also the file name, and what `--snapshot` accepts.
    var generation: String
    var createdAt: Date
    var app: String
    var bundle: String
    var pid: Int32
    var windowIndex: Int
    var windowTitle: String
    var windowCount: Int
    var nodes: [AXSnapshotNode]

    func node(ref: String) -> AXSnapshotNode? {
        nodes.first { $0.ref == ref }
    }
}

/// One line of `index.json`: a ref, and which dump last printed it.
struct AXIndexEntry: Codable, Equatable {
    var generation: String
    var app: String
    var bundle: String
    var pid: Int32
    var window: Int
    var title: String
    var at: Date

    /// Which snapshot this ref belongs to, for an error message that names the app.
    var origin: String {
        app.isEmpty ? bundle : app
    }
}

/// The ref → snapshot map, so `press @e7` can find the dump that printed it.
struct AXIndex: Codable, Equatable {
    static let schema = 1
    var schema: Int
    var refs: [String: [AXIndexEntry]]
    /// Highest ref handed out per window (`bundle|window`). Refs are monotonic per window so a
    /// re-dump never reuses a number: if `tree` prints @e15 and a later `find` renumbered from
    /// 1, `press @e15` would act on a node the reader never saw. Measured the hard way on
    /// macOS 26: a checkbox press renumbered the next dump and @e19 became the ruler.
    var counters: [String: Int]

    init(schema: Int = AXIndex.schema, refs: [String: [AXIndexEntry]] = [:], counters: [String: Int] = [:]) {
        self.schema = schema
        self.refs = refs
        self.counters = counters
    }

    /// Tolerate an index written by the previous build (no `counters`): a stale cache must not
    /// turn every ref into an error.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? AXIndex.schema
        refs = try container.decodeIfPresent([String: [AXIndexEntry]].self, forKey: .refs) ?? [:]
        counters = try container.decodeIfPresent([String: Int].self, forKey: .counters) ?? [:]
    }

    static func counterKey(bundle: String, window: Int) -> String {
        "\(bundle.isEmpty ? "pid" : bundle)|\(window)"
    }

    /// Where the next dump of this window starts numbering.
    func nextRef(bundle: String, window: Int) -> Int {
        (counters[AXIndex.counterKey(bundle: bundle, window: window)] ?? 0) + 1
    }

    /// Merge a new dump. Refs are monotonic per window, so a new dump cannot reuse an old
    /// number; the dedupe below only matters when a counter was reset (its snapshots pruned).
    /// A ref the new dump does not reprint keeps pointing at the dump that printed it.
    mutating func record(_ snapshot: AXSnapshot) {
        let entry = AXIndexEntry(generation: snapshot.generation, app: snapshot.app,
                                 bundle: snapshot.bundle, pid: snapshot.pid,
                                 window: snapshot.windowIndex, title: snapshot.windowTitle,
                                 at: snapshot.createdAt)
        for node in snapshot.nodes {
            var list = refs[node.ref] ?? []
            list.removeAll { $0.bundle == entry.bundle && $0.window == entry.window }
            list.append(entry)
            refs[node.ref] = list
        }
    }

    mutating func noteRefs(bundle: String, window: Int, upTo index: Int) {
        let key = AXIndex.counterKey(bundle: bundle, window: window)
        counters[key] = max(counters[key] ?? 0, index)
    }

    /// Candidates for a ref, newest first, optionally narrowed to one app.
    func candidates(for ref: AXRef, app: String? = nil) -> [AXIndexEntry] {
        let all = (refs[ref.description] ?? []).sorted { $0.at > $1.at }
        guard let app, !app.isEmpty else { return all }
        let lowered = app.lowercased()
        return all.filter {
            $0.bundle.lowercased() == lowered || $0.app.lowercased() == lowered
                || $0.app.lowercased().contains(lowered)
        }
    }
}

/// Where snapshots live and how they are read and written. No daemon: a directory of JSON files
/// that the next process opens, with the index as the only thing that has to stay consistent.
struct AXRefStore {
    var directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? AXRefStore.defaultDirectory()
    }

    /// `KRD_AX_STATE` exists so tests (and a user with a read-only $TMPDIR) can move the state
    /// somewhere else; `NSTemporaryDirectory()` is per-user on macOS and survives between
    /// invocations, which is all a ref needs.
    static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["KRD_AX_STATE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("krd-ax", isDirectory: true)
    }

    private var snapshotsDirectory: URL { directory.appendingPathComponent("snapshots", isDirectory: true) }
    private var indexPath: URL { directory.appendingPathComponent("index.json") }
    /// How many dumps of one window are kept.
    ///
    /// Every `tree`/`find` writes one, and refs are monotonic, so this is really "how far back
    /// can a ref reach". Measured the hard way: at 4, a `tree` → `find` → `tree` → `press`
    /// sequence pruned the dump the agent was still holding a ref from. 16 snapshots of ~50
    /// nodes are a few hundred KB, which $TMPDIR carries without noticing.
    static let keepPerWindow = 16

    func snapshotPath(generation: String) -> URL {
        snapshotsDirectory.appendingPathComponent("\(generation).json")
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
    }

    func loadIndex() -> AXIndex {
        guard let data = try? Data(contentsOf: indexPath),
              let index = try? JSONDecoder().decode(AXIndex.self, from: data) else { return AXIndex() }
        return index
    }

    func saveIndex(_ index: AXIndex) throws {
        try ensureDirectories()
        // Default Date coding (seconds since 2001 as a Double): exact round-trip, and a
        // snapshot written twice in the same second still compares and orders correctly.
        try JSONEncoder().encode(index).write(to: indexPath, options: .atomic)
    }

    /// Persist a dump and point the index at it.
    func save(_ snapshot: AXSnapshot) throws {
        try ensureDirectories()
        try JSONEncoder().encode(snapshot)
            .write(to: snapshotPath(generation: snapshot.generation), options: .atomic)
        var index = loadIndex()
        index.record(snapshot)
        if let highest = snapshot.nodes.compactMap({ AXRef($0.ref)?.index }).max() {
            index.noteRefs(bundle: snapshot.bundle, window: snapshot.windowIndex, upTo: highest)
        }
        index.refs = index.refs.filter { !$0.value.isEmpty }
        try saveIndex(index)
        prune(bundle: snapshot.bundle, window: snapshot.windowIndex)
    }

    /// The first ref number a new dump of this window should use.
    func nextRef(bundle: String, window: Int) -> Int {
        loadIndex().nextRef(bundle: bundle, window: window)
    }

    func load(generation: String) -> AXSnapshot? {
        guard let data = try? Data(contentsOf: snapshotPath(generation: generation)) else { return nil }
        return try? JSONDecoder().decode(AXSnapshot.self, from: data)
    }

    /// Load by generation id or by path, which is what `--snapshot` accepts.
    func load(reference: String) -> AXSnapshot? {
        if reference.contains("/") || reference.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: reference)) else { return nil }
            return try? JSONDecoder().decode(AXSnapshot.self, from: data)
        }
        return load(generation: reference)
    }

    /// Keep the newest `keepPerWindow` dumps of one window, and drop index entries whose file
    /// is gone: a ref may only ever point at something that still exists.
    func prune(bundle: String, window: Int, keep: Int = AXRefStore.keepPerWindow) {
        var index = loadIndex()
        let mine = Set(index.refs.values.flatMap { $0 }
            .filter { $0.bundle == bundle && $0.window == window }
            .map { $0.generation })
        let ordered = mine.compactMap { generation -> (String, Date)? in
            guard let snapshot = load(generation: generation) else { return nil }
            return (generation, snapshot.createdAt)
        }.sorted { $0.1 > $1.1 }
        for (generation, _) in ordered.dropFirst(keep) {
            try? FileManager.default.removeItem(at: snapshotPath(generation: generation))
            for (ref, list) in index.refs {
                index.refs[ref] = list.filter { $0.generation != generation }
            }
        }
        index.refs = index.refs.filter { !$0.value.isEmpty }
        let key = AXIndex.counterKey(bundle: bundle, window: window)
        let stillReferenced = index.refs.values.flatMap { $0 }
            .contains { $0.bundle == bundle && $0.window == window }
        if !stillReferenced { index.counters[key] = nil }
        try? saveIndex(index)
    }
}
