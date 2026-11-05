import Foundation
import Semantic

/// One hit in one interface. Carries everything the result row and the
/// content pane's second-stage locate need; the interface text itself stays
/// in the engine process.
public struct RuntimeInterfaceSearchMatch: Hashable, Codable, Sendable {
    public let object: RuntimeObject
    /// 1-based line in the interface as the query's options show it.
    public let lineNumber: Int
    /// The hit's line, possibly windowed around the hit when the line is very
    /// long — `matchRangeInLine` is relative to this text either way.
    public let lineText: String
    public let matchRangeInLine: RuntimeTextRange
    public let semanticKind: RuntimeSemanticKind

    public init(object: RuntimeObject, lineNumber: Int, lineText: String, matchRangeInLine: RuntimeTextRange, semanticKind: RuntimeSemanticKind) {
        self.object = object
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.matchRangeInLine = matchRangeInLine
        self.semanticKind = semanticKind
    }
}

extension RuntimeInterfaceSearchMatch {
    /// What a text match carries besides its object.
    struct Hit: Codable, Sendable {
        let lineNumber: Int
        let lineText: String
        let matchRangeInLine: RuntimeTextRange
        let semanticKind: RuntimeSemanticKind
    }
}
