import Foundation
import Semantic

// MARK: - Query

public struct RuntimeInterfaceSearchQuery: Hashable, Codable, Sendable {
    public var text: String
    public var matchMode: RuntimeInterfaceSearchMatchMode
    public var isCaseSensitive: Bool
    public var scope: RuntimeInterfaceSearchScope
    /// Matches are collected up to this many across every image; scanning
    /// goes on to count the rest, so `RuntimeInterfaceSearchSummary.totalMatchCount`
    /// is the real total even when `isTruncated` is set.
    public var resultLimit: Int
    /// The options the interfaces are read under — the content pane's — so
    /// only what it shows is found and each line reads as it displays.
    /// `nil` searches everything any options could show. The transformer
    /// part is not consulted: the corpus is already printed with it.
    public var generationOptions: RuntimeObjectInterface.GenerationOptions?
    /// The images to search, of those with a corpus; `nil` searches all of
    /// them. The Find navigator's scope arrives here, and a search already
    /// shown widens itself this way to an image whose corpus was built after
    /// it ran.
    public var imagePaths: Set<String>?

    public init(
        text: String,
        matchMode: RuntimeInterfaceSearchMatchMode = .containing,
        isCaseSensitive: Bool = false,
        scope: RuntimeInterfaceSearchScope = .all,
        resultLimit: Int = 1000,
        generationOptions: RuntimeObjectInterface.GenerationOptions? = nil,
        imagePaths: Set<String>? = nil
    ) {
        self.text = text
        self.matchMode = matchMode
        self.isCaseSensitive = isCaseSensitive
        self.scope = scope
        self.resultLimit = resultLimit
        self.generationOptions = generationOptions
        self.imagePaths = imagePaths
    }
}
