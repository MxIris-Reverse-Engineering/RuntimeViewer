import Foundation

/// What the naming word cloud windows share and remember across launches: the
/// measure, the member group, the switches of the ⚙︎ menu, how many words the
/// cloud draws, and the user's changes to the compound words. Stored in
/// `AppDefaults.namingWordCloudPreferences`; a value missing from what was
/// stored reads as its default, so a later release can add one.
public struct NamingWordCloudPreferences: Codable, Hashable, Sendable {
    public var measure: NamingWordMeasure = .typeSuffixes

    /// The group Member Words is limited to; `nil` counts every member.
    public var memberGroup: NamingMemberGroup?

    /// Remove Prefixes.
    public var removesPrefixes = true

    /// Ignore Common Words.
    public var ignoresCommonWords = true

    /// Merge Compound Words.
    public var mergesCompoundWords = true

    /// How many of the most common words the cloud draws; `nil` draws all.
    public var wordLimit: Int? = 150

    /// Compound words the user added to the presets.
    public var addedCompoundWords: [String] = []

    /// Presets the user removed.
    public var removedPresetCompoundWords: [String] = []

    /// The word counts the ⚙︎ menu offers; `nil` is All.
    public static let wordLimitChoices: [Int?] = [150, 300, 500, 1000, nil]

    public init() {}

    /// The compound words in effect: the presets less the removed ones, plus
    /// the added ones.
    public var compoundWords: NamingCompoundWords {
        NamingCompoundWords.effective(addedWords: addedCompoundWords, removedPresetWords: removedPresetCompoundWords)
    }

    private enum CodingKeys: String, CodingKey {
        case measure, memberGroup, removesPrefixes, ignoresCommonWords, mergesCompoundWords, wordLimit, addedCompoundWords, removedPresetCompoundWords
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NamingWordCloudPreferences()
        measure = (try? container.decodeIfPresent(NamingWordMeasure.self, forKey: .measure)) ?? defaults.measure
        memberGroup = try? container.decodeIfPresent(NamingMemberGroup.self, forKey: .memberGroup)
        removesPrefixes = (try? container.decodeIfPresent(Bool.self, forKey: .removesPrefixes)) ?? defaults.removesPrefixes
        ignoresCommonWords = (try? container.decodeIfPresent(Bool.self, forKey: .ignoresCommonWords)) ?? defaults.ignoresCommonWords
        mergesCompoundWords = (try? container.decodeIfPresent(Bool.self, forKey: .mergesCompoundWords)) ?? defaults.mergesCompoundWords
        // A stored `nil` is All; a missing key is the default.
        if container.contains(.wordLimit) {
            wordLimit = try? container.decodeIfPresent(Int.self, forKey: .wordLimit)
        } else {
            wordLimit = defaults.wordLimit
        }
        addedCompoundWords = (try? container.decodeIfPresent([String].self, forKey: .addedCompoundWords)) ?? []
        removedPresetCompoundWords = (try? container.decodeIfPresent([String].self, forKey: .removedPresetCompoundWords)) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(measure, forKey: .measure)
        try container.encode(memberGroup, forKey: .memberGroup)
        try container.encode(removesPrefixes, forKey: .removesPrefixes)
        try container.encode(ignoresCommonWords, forKey: .ignoresCommonWords)
        try container.encode(mergesCompoundWords, forKey: .mergesCompoundWords)
        try container.encode(wordLimit, forKey: .wordLimit)
        try container.encode(addedCompoundWords, forKey: .addedCompoundWords)
        try container.encode(removedPresetCompoundWords, forKey: .removedPresetCompoundWords)
    }
}
