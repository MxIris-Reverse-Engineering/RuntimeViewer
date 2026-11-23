import Foundation
import Testing
import Semantic
@testable import RuntimeViewerCore

/// `RuntimeSemanticKind` crosses the engine boundary as a raw string, so a semantic type added after
/// it shipped folds into a kind every peer already decodes instead of getting a case of its own.
@Suite("RuntimeSemanticKind")
struct RuntimeSemanticKindTests {
    /// An Objective-C header's `NS_SWIFT_NAME` / `NS_REFINED_FOR_SWIFT` are `.macro` runs. A search
    /// hit in one is a keyword hit, which a peer built before macros were marked decodes too.
    @Test("a macro folds into keyword, which every peer decodes, and is no symbol")
    func macroFoldsIntoKeyword() throws {
        let kind = RuntimeSemanticKind(.macro)
        #expect(kind == .keyword)
        #expect(!kind.isSymbol)
        #expect(RuntimeSemanticKind.allCases.map(\.rawValue).contains(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(kind))))
    }
}
