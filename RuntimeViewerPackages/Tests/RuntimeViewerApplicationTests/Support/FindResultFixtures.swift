import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerApplication

/// Find result trees built by hand: a type row per name, with text hits under it. Every call
/// builds new instances, the way a search builds rows for each batch it delivers.
enum FindResultFixtures {
    static func object(named name: String, displayName: String? = nil) -> RuntimeObject {
        Fixtures.runtimeObject(name: name, displayName: displayName, kind: .objc(.type(.class)))
    }

    static func hit(in name: String, lineNumber: Int, lineText: String = "- (void)sample;") -> RuntimeInterfaceSearchMatch {
        RuntimeInterfaceSearchMatch(
            object: object(named: name),
            lineNumber: lineNumber,
            lineText: lineText,
            matchRangeInLine: RuntimeTextRange(location: 0, length: 1),
            semanticKind: .function
        )
    }

    /// The row of `object` with `hits` beneath it, as a text search groups them.
    static func type(_ object: RuntimeObject, hits: [RuntimeInterfaceSearchMatch]) -> FindResultNode {
        let hitNodes = hits.enumerated().map { index, hit in
            FindResultNode.textMatch(hit, index: index)
        }
        return FindResultNode.object(object, matchCount: hitNodes.count, children: hitNodes)
    }

    /// A type row named `name` with `hitCount` hits, on lines 1 through `hitCount`.
    static func type(_ name: String, hitCount: Int) -> FindResultNode {
        type(object(named: name), hits: (0 ..< hitCount).map { index in hit(in: name, lineNumber: index + 1) })
    }

    /// A node of a relationship tree under `path`, as a relationship search lays one out.
    static func relationship(named name: String, path: String, children: [FindResultNode] = []) -> FindResultNode {
        FindResultNode(content: .relationship(name: name, object: object(named: name)), children: children, identifier: "\(path)/\(name)")
    }
}
