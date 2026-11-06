import RuntimeViewerCore

/// A query for the content pane's own find bar, which marks every match in the
/// object on screen: the search a Find navigator text hit came from, matched the
/// way that search matched it.
public struct ContentFindBarQuery: Hashable, Sendable {
    /// The search text — for a query with find patterns, the regular expression
    /// the search sent the engine.
    public let text: String
    public let matchMode: RuntimeInterfaceSearchMatchMode
    public let isCaseSensitive: Bool

    public init(text: String, matchMode: RuntimeInterfaceSearchMatchMode, isCaseSensitive: Bool) {
        self.text = text
        self.matchMode = matchMode
        self.isCaseSensitive = isCaseSensitive
    }
}
