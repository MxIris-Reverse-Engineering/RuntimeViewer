import Foundation
public import Semantic

// MARK: - Semantic kinds

/// `Semantic.SemanticType` flattened to a `Codable` enum that crosses the
/// engine boundary. The type's own `TypeKind` / `Context` payloads are folded
/// away: a search result needs to know that a hit sits in a type name or a
/// comment, not whether the type is a struct or a class.
public enum RuntimeSemanticKind: String, Codable, Hashable, Sendable, CaseIterable {
    case standard
    case comment
    case keyword
    case variable
    case numeric
    case argument
    case error
    case type
    case member
    case function
    case other

    public init(_ semanticType: SemanticType) {
        switch semanticType {
        case .standard: self = .standard
        case .comment: self = .comment
        case .keyword: self = .keyword
        case .variable: self = .variable
        case .numeric: self = .numeric
        case .argument: self = .argument
        case .error: self = .error
        case .type: self = .type
        case .member: self = .member
        case .function: self = .function
        case .other: self = .other
        }
    }

    /// Identifier-like kinds — what "symbols only" means.
    public var isSymbol: Bool {
        switch self {
        case .type, .member, .function, .variable, .argument: true
        case .standard, .comment, .keyword, .numeric, .error, .other: false
        }
    }
}

// MARK: - Query

/// How the query text is matched against interface text — Xcode's four text
/// match styles plus regular expressions.
public enum RuntimeInterfaceSearchMatchMode: String, Codable, Hashable, Sendable, CaseIterable {
    case containing
    case matchingWord
    case startingWith
    case endingWith
    case regularExpression
}

/// Which parts of an interface a hit may land in. The mapping to
/// `RuntimeSemanticKind` is closed: `symbolsOnly` is exactly the kinds whose
/// `isSymbol` is true; `keyword`, `standard`, `numeric`, `error` and `other`
/// are matched by `all` and `excludeComments` alone.
public enum RuntimeInterfaceSearchScope: String, Codable, Hashable, Sendable, CaseIterable {
    case all
    case excludeComments
    case commentsOnly
    case symbolsOnly

    public func includes(_ kind: RuntimeSemanticKind) -> Bool {
        switch self {
        case .all: true
        case .excludeComments: kind != .comment
        case .commentsOnly: kind == .comment
        case .symbolsOnly: kind.isSymbol
        }
    }
}

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

// MARK: - Results

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

/// What a text or member search covered, and how much of it reached the
/// caller. Shared by both searches because the questions are the same.
public struct RuntimeInterfaceSearchSummary: Hashable, Codable, Sendable {
    /// Real total, counted past `resultLimit`.
    public let totalMatchCount: Int
    /// The images whose corpus the search read, in the order it read them.
    public let scannedImagePaths: [String]
    public let scannedObjectCount: Int
    /// `true` when more hits exist than were collected.
    public let isTruncated: Bool
    /// Indexed images with no corpus yet (pending, building or failed), so
    /// the UI can say what the search did not see. Only the images the query
    /// covers count: every indexed image, or those of its `imagePaths`.
    public let unbuiltIndexedImagePaths: [String]

    public var scannedImageCount: Int {
        scannedImagePaths.count
    }

    public init(totalMatchCount: Int, scannedImagePaths: [String], scannedObjectCount: Int, isTruncated: Bool, unbuiltIndexedImagePaths: [String]) {
        self.totalMatchCount = totalMatchCount
        self.scannedImagePaths = scannedImagePaths
        self.scannedObjectCount = scannedObjectCount
        self.isTruncated = isTruncated
        self.unbuiltIndexedImagePaths = unbuiltIndexedImagePaths
    }
}

// MARK: - Corpus building

/// Progress of one image's corpus build: objects printed so far out of the
/// image's total. A named struct rather than a tuple because
/// `RuntimeEngineProgressRequest.Progress` has to be `Codable`.
public struct RuntimeInterfaceCorpusBuildProgress: Hashable, Codable, Sendable {
    public let built: Int
    public let total: Int

    public init(built: Int, total: Int) {
        self.built = built
        self.total = total
    }
}

public struct RuntimeInterfaceCorpusBuildSummary: Hashable, Codable, Sendable {
    /// Objects whose interface is in the corpus.
    public let objectCount: Int
    /// Objects whose interface failed to print and were left out. A build
    /// with skipped objects still counts as built.
    public let skippedCount: Int
    /// Resident bytes of the image's corpus: text plus span tables.
    public let byteCount: Int

    public init(objectCount: Int, skippedCount: Int, byteCount: Int) {
        self.objectCount = objectCount
        self.skippedCount = skippedCount
        self.byteCount = byteCount
    }
}

/// Where one image's corpus stands.
///
/// There is no "unbuilt" case: an image absent from the coverage map is one
/// the store holds nothing for — never asked for, evicted, or cancelled
/// before it finished. Cancellation deliberately leaves no `failed` behind;
/// a build that threw does, and stays there until something asks for that
/// image again.
public enum RuntimeInterfaceCorpusBuildState: Hashable, Codable, Sendable {
    case pending
    case building(RuntimeInterfaceCorpusBuildProgress)
    case built(RuntimeInterfaceCorpusBuildSummary)
    case failed(message: String)

    public var isBuilt: Bool {
        if case .built = self { return true }
        return false
    }

    /// Waiting for its turn or being printed.
    public var isActive: Bool {
        switch self {
        case .pending, .building: true
        case .built, .failed: false
        }
    }
}

/// The coverage the store reports: one state per image it knows about, plus
/// the resident budget.
public struct RuntimeInterfaceCorpusCoverage: Hashable, Codable, Sendable {
    public let statesByImagePath: [String: RuntimeInterfaceCorpusBuildState]
    public let residentByteCount: Int
    public let residentByteLimit: Int

    public init(statesByImagePath: [String: RuntimeInterfaceCorpusBuildState], residentByteCount: Int, residentByteLimit: Int) {
        self.statesByImagePath = statesByImagePath
        self.residentByteCount = residentByteCount
        self.residentByteLimit = residentByteLimit
    }

    public static let empty = RuntimeInterfaceCorpusCoverage(statesByImagePath: [:], residentByteCount: 0, residentByteLimit: 0)
}
