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
            return
        }
        sortedRanges = zip(semanticRanges, nodeTypeNames)
            .compactMap { range, name in
                guard let identifier = NodeTypeRegistry.identifier(forName: name) else { return nil }
                return (range, identifier)
            }
            .sorted { $0.range.location < $1.range.location }
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
}
