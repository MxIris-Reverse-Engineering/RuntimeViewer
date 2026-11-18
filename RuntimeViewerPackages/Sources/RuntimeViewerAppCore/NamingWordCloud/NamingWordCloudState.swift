import Foundation

/// What a naming word cloud window shows: one value for loading and content
/// alike, so the window never shows one image's cloud under another's progress.
public enum NamingWordCloudState: Equatable, Sendable {
    /// The image is being loaded and indexed, or its types read.
    case indexingImage(fractionCompleted: Double?)
    /// The image's Find corpus is being built, for the member measures.
    case buildingCorpus(fractionCompleted: Double?)
    case ready(NamingWordCloudContent)
    /// The measure cannot be counted here, for a reason that is not a failure.
    case unavailable(NamingWordCloudUnavailability)
    /// Something went wrong; Retry starts over.
    case failed(message: String)
}

/// Why a measure cannot be counted.
public enum NamingWordCloudUnavailability: Equatable, Sendable {
    /// The member measures read the Find corpus, and Settings › Search has it off.
    case corpusDisabled
    /// The engine's peer is older than the command that lists a corpus's members.
    case peerTooOld
    /// The document keeps no background work, so nothing can build the corpus.
    case corpusUnreachable
    /// The image has no names the measure counts.
    case nothingToCount

    public var message: String {
        switch self {
        case .corpusDisabled:
            "Member names come from the Find corpus. Turn on Searchable Interfaces in Settings › Search to count them. Type Suffixes and Type Words work without it."
        case .peerTooOld:
            "The process this engine reaches is too old to list member names. Type Suffixes and Type Words still work."
        case .corpusUnreachable:
            "This window cannot build the Find corpus for member names."
        case .nothingToCount:
            "There are no names to count."
        }
    }
}

/// A cloud ready to draw: the words it draws, the full ranking, and the
/// categories its colours stand for.
public struct NamingWordCloudContent: Equatable, Sendable {
    public let measure: NamingWordMeasure

    /// The most common words, as many as the word limit allows, the most
    /// common first: what the cloud draws.
    public let cloudWords: [NamingWordCloudWord]

    /// Every counted word, the most common first: what the ranking lists and
    /// the exports hold.
    public let rankedWords: [NamingWordCloudWord]

    /// The categories `cloudWords` are coloured as, in the measure's order:
    /// the legend lists only these.
    public let legend: [NamingWordCategory]

    /// The class prefix taken off type names, when one was.
    public let removedTypePrefix: String?

    public init(measure: NamingWordMeasure, cloudWords: [NamingWordCloudWord], rankedWords: [NamingWordCloudWord], removedTypePrefix: String?) {
        self.measure = measure
        self.cloudWords = cloudWords
        self.rankedWords = rankedWords
        self.removedTypePrefix = removedTypePrefix
        let usedCategories = Set(cloudWords.map(\.category))
        legend = measure.categories.filter(usedCategories.contains)
    }
}

/// One word as the window shows it.
public struct NamingWordCloudWord: Hashable, Sendable, Identifiable {
    public let key: String
    public let word: String
    public let count: Int
    public let category: NamingWordCategory

    public var id: String { key }

    public var color: ColorDescriptor { .namingWordCategory(category) }

    public init(_ wordCount: NamingWordCount) {
        key = wordCount.key
        word = wordCount.word
        count = wordCount.count
        category = wordCount.category
    }
}

/// A name that holds the selected word, as the usage list shows it: a type
/// with its kind, or a member with the type that declares it.
public struct NamingWordCloudUsageRow: Hashable, Sendable {
    public let name: String
    public let detail: String

    public init(_ usage: NamingWordUsage) {
        switch usage {
        case .type(let object):
            name = object.displayName
            detail = usage.kindName
        case .member(let member, let object):
            name = member.name
            detail = object.displayName
        }
    }
}

/// What the Export menu writes.
public enum NamingWordCloudExportFormat: String, CaseIterable, Hashable, Sendable {
    /// The whole canvas, drawn by the view.
    case image
    case csv
    case json

    public var fileExtension: String {
        switch self {
        case .image: "png"
        case .csv: "csv"
        case .json: "json"
        }
    }

    public var menuTitle: String {
        switch self {
        case .image: "Export Image…"
        case .csv: "Export Word Counts as CSV…"
        case .json: "Export Word Counts as JSON…"
        }
    }
}
