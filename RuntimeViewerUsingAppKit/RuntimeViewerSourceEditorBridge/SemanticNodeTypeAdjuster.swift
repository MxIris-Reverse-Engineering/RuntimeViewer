import AppKit
import SourceModel
import SourceModelSupport

/// Retypes the parser's nodes from what a lexical scan could work out to what RuntimeViewer
/// actually knows.
///
/// The framework parses plain text, so `NSString` in `@property (copy) NSString *action` is
/// just an identifier to it — there is nothing in the text that says it is a class. The
/// interface being displayed, though, was rendered from runtime metadata, so the generator knew
/// exactly what every identifier was and recorded it as a semantic type on the attributed
/// string. This replays that knowledge into the parse.
///
/// **This is the framework's own extension point, not a workaround.** A language service hands
/// every parsed node to its `nodeTypeAdjuster` before use, which is how Xcode upgrades a
/// lexical parse with index data. Retyping here means the editor's *own* machinery becomes
/// semantic — colouring, but also `tokenRangeAtPosition`, delimiter matching and structural
/// selection — rather than having correct colours painted over an incorrect parse.
///
/// One class of node never reaches this adjuster on its own; see
/// ``SourceModelDeclarationShortCircuitOverride`` for what gets it here.
final class SemanticNodeTypeAdjuster: SourceModelNodeTypeAdjuster {
    /// Node type ids, resolved by name once per process.
    ///
    /// The registry assigns ids in registration order, so they are not stable across versions;
    /// the *names* are, and they are exactly the theme's syntax keys, which is why retyping a
    /// node is all it takes to change how it is coloured.
    private enum NodeTypeRegistry {
        static let idsByName: [String: Int16] = {
            var ids: [String: Int16] = [:]
            let count = Int(SMSourceNodeTypes.nodeTypesCount())
            for identifier in 0 ..< count {
                guard let name = SMSourceNodeTypes.nodeTypeName(forId: Int16(identifier)) else { continue }
                ids[name] = Int16(identifier)
            }
            return ids
        }()

        static func identifier(forName name: String) -> Int16? { idsByName[name] }
    }

    /// Sorted by location so a node can be matched with a binary search; the parser asks about
    /// nodes in no particular order and a large interface has tens of thousands of them.
    private var sortedRanges: [(range: NSRange, nodeTypeIdentifier: Int16)] = []

    /// - Parameters:
    ///   - semanticRanges: UTF-16 ranges into the displayed text.
    ///   - nodeTypeNames: parallel to `semanticRanges`. A name the registry does not know is
    ///     dropped rather than guessed at, so an unfamiliar Xcode simply colors those runs the
    ///     way it would have anyway.
    func load(semanticRanges: [NSRange], nodeTypeNames: [String]) {
        guard semanticRanges.count == nodeTypeNames.count else {
            sortedRanges = []
            Self.typeReferenceRanges.removeSnapshot(for: self)
            return
        }
        sortedRanges = zip(semanticRanges, nodeTypeNames)
            .compactMap { range, name in
                guard let identifier = NodeTypeRegistry.identifier(forName: name) else { return nil }
                return (range, identifier)
            }
            .sorted { $0.range.location < $1.range.location }

        Self.typeReferenceRanges.storeSnapshot(
            zip(semanticRanges, nodeTypeNames)
                .filter { Self.isReferenceNodeTypeName($1) }
                .map(\.0)
                .sorted { $0.location < $1.location },
            for: self
        )
    }

    deinit {
        Self.typeReferenceRanges.removeSnapshot(for: self)
    }

    // `invalidateCache()` is deliberately NOT implemented. It has a default in the framework's
    // protocol extension, and overriding it with a no-op stops the retyping from reaching the
    // render — the default evidently does work the parse depends on. Requirements that come
    // with a default are the framework's business unless there is a reason to take them over.

    func adjustNodeType(for item: SMSourceModelItem) {
        let itemRange = item.range
        guard itemRange.length > 0, let identifier = nodeTypeIdentifier(fullyContaining: itemRange) else { return }
        item.setNodeType(identifier)
    }

    /// A node is retyped only when one semantic run contains **all** of it.
    ///
    /// The parser's nodes and the generator's runs do not agree on boundaries: a node can span
    /// several runs — in an Objective-C method declaration one covers the parameter type *and*
    /// the parameter name that follows. Matching on the node's first character alone was enough
    /// to colour those names as types, since the node inherited whatever its opening character
    /// belonged to. Requiring containment costs a few nodes that straddle runs, which simply
    /// keep the parse the framework made of them, and never mislabels one.
    private func nodeTypeIdentifier(fullyContaining nodeRange: NSRange) -> Int16? {
        var low = 0
        var high = sortedRanges.count - 1
        var candidate: Int?
        while low <= high {
            let middle = (low + high) / 2
            if sortedRanges[middle].range.location <= nodeRange.location {
                candidate = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let index = candidate else { return nil }
        let entry = sortedRanges[index]
        guard nodeRange.location + nodeRange.length <= entry.range.location + entry.range.length else { return nil }
        return entry.nodeTypeIdentifier
    }

    // MARK: - Reference Ranges

    /// Node type names are hierarchical, and the two halves of the hierarchy that matter here
    /// say opposite things: everything under `xcode.syntax.identifier` names a *use* of
    /// something, while `xcode.syntax.declaration.*` names the place it is introduced. The app
    /// side assigns the first to every `.name` semantic and the second to every `.declaration`
    /// one, so the prefix separates references from declarations without the bundle linking
    /// anything from the app — which it must not do, for the reasons in `SourceEditorBridging`.
    private static func isReferenceNodeTypeName(_ name: String) -> Bool {
        name.hasPrefix("xcode.syntax.identifier")
    }

    /// The reference ranges of every adjuster that currently holds any, so
    /// ``SourceModelDeclarationShortCircuitOverride`` can answer for whichever document the
    /// framework is parsing. It is handed a location and an `SMSourceModel`, with no way back
    /// to the adjuster installed on that model's language service — hence a shared registry
    /// rather than a lookup.
    ///
    /// Asking on behalf of all documents at once cannot produce a wrong colour. A location one
    /// document calls a reference and another calls a declaration still arrives at the second
    /// document's own adjuster, which retypes it from that document's runs; the override only
    /// decides *whether* the adjuster is consulted, never what it answers.
    private static let typeReferenceRanges = TypeReferenceRangeRegistry()

    /// Whether any displayed interface labels `location` as a reference to a named entity.
    static func isTypeReferenceLocation(_ location: Int) -> Bool {
        typeReferenceRanges.containsLocation(location)
    }
}

/// Immutable per-adjuster snapshots of the reference ranges, behind a lock.
///
/// Snapshots are stored whole and never mutated in place, so a reader holds a plain `let` array
/// once the lock is released. That matters because the parse that queries this runs on
/// whichever thread the editor parses on, while the snapshots are stored from the main thread.
private final class TypeReferenceRangeRegistry {
    private let lock = NSLock()
    private var snapshotsByAdjuster: [ObjectIdentifier: [NSRange]] = [:]

    func storeSnapshot(_ sortedRanges: [NSRange], for adjuster: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        snapshotsByAdjuster[ObjectIdentifier(adjuster)] = sortedRanges
    }

    func removeSnapshot(for adjuster: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        snapshotsByAdjuster.removeValue(forKey: ObjectIdentifier(adjuster))
    }

    func containsLocation(_ location: Int) -> Bool {
        lock.lock()
        let snapshots = Array(snapshotsByAdjuster.values)
        lock.unlock()
        return snapshots.contains { Self.sortedRanges($0, contain: location) }
    }

    private static func sortedRanges(_ sortedRanges: [NSRange], contain location: Int) -> Bool {
        var low = 0
        var high = sortedRanges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = sortedRanges[middle]
            if location < range.location {
                high = middle - 1
            } else if location >= range.location + range.length {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }
}
