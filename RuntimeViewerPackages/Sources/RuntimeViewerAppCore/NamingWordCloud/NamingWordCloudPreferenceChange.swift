import Foundation

/// One change the naming word cloud window's controls make to the shared
/// preferences.
public enum NamingWordCloudPreferenceChange: Hashable, Sendable {
    case measure(NamingWordMeasure)
    case memberGroup(NamingMemberGroup?)
    case removesPrefixes(Bool)
    case ignoresCommonWords(Bool)
    case mergesCompoundWords(Bool)
    case wordLimit(Int?)
    case compoundWords(added: [String], removedPresets: [String])

    public func apply(to preferences: inout NamingWordCloudPreferences) {
        switch self {
        case .measure(let measure):
            preferences.measure = measure
        case .memberGroup(let memberGroup):
            preferences.memberGroup = memberGroup
        case .removesPrefixes(let removesPrefixes):
            preferences.removesPrefixes = removesPrefixes
        case .ignoresCommonWords(let ignoresCommonWords):
            preferences.ignoresCommonWords = ignoresCommonWords
        case .mergesCompoundWords(let mergesCompoundWords):
            preferences.mergesCompoundWords = mergesCompoundWords
        case .wordLimit(let wordLimit):
            preferences.wordLimit = wordLimit
        case .compoundWords(let added, let removedPresets):
            preferences.addedCompoundWords = added
            preferences.removedPresetCompoundWords = removedPresets
        }
    }
}
