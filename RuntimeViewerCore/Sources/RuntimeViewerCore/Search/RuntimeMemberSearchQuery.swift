import Foundation

/// The member mode's query: what to look for in member names and how, an
/// optional kind filter, case sensitivity and the global result cap.
public struct RuntimeMemberSearchQuery: Hashable, Codable, Sendable {
    public var text: String
    /// How `text` is matched against a member's name — the text search's
    /// match styles under the text search's rules, so each piece of a
    /// multi-part selector is a word of its own.
    public var matchMode: RuntimeInterfaceSearchMatchMode
    /// `nil` means every kind.
    public var kinds: Set<RuntimeMemberKind>?
    public var isCaseSensitive: Bool
    /// Matches are collected up to this many; scanning goes on to count the
    /// rest, so the summary's total is the real total.
    public var resultLimit: Int
    /// The options the members are read under — the content pane's — so a
    /// member they strip is not found, and a found one's line reads as
    /// displayed. `nil` searches every member any options could show.
    public var generationOptions: RuntimeObjectInterface.GenerationOptions?
    /// The images to search, of those with a corpus; `nil` searches all of
    /// them. See `RuntimeInterfaceSearchQuery.imagePaths`.
    public var imagePaths: Set<String>?

    public init(
        text: String,
        matchMode: RuntimeInterfaceSearchMatchMode = .containing,
        kinds: Set<RuntimeMemberKind>? = nil,
        isCaseSensitive: Bool = false,
        resultLimit: Int = 1000,
        generationOptions: RuntimeObjectInterface.GenerationOptions? = nil,
        imagePaths: Set<String>? = nil
    ) {
        self.text = text
        self.matchMode = matchMode
        self.kinds = kinds
        self.isCaseSensitive = isCaseSensitive
        self.resultLimit = resultLimit
        self.generationOptions = generationOptions
        self.imagePaths = imagePaths
    }
}
