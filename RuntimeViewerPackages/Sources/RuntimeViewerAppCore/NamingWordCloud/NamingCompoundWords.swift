import Foundation

/// Words that always come in pairs and change meaning when split, counted as
/// one word: `NSTableViewDataSource` ends in `DataSource`, not `Source`, and
/// `tableView:cellForRowAtIndexPath:` holds `IndexPath`.
///
/// The presets come with the app; the user adds words and removes presets in
/// the window's Compound Words sheet, and those changes are what is stored,
/// so a later release can add presets of its own.
public struct NamingCompoundWords: Hashable, Sendable {
    /// Each compound word as the words it is made of, in lowercase, longest
    /// first so that the longest match wins.
    private let wordSequences: [[String]]

    /// The compound words, as spelled.
    public let words: [String]

    public init(words: [String]) {
        var seenKeys: Set<String> = []
        let uniqueWords = words.filter { word in
            let key = word.lowercased()
            guard !key.isEmpty, !seenKeys.contains(key) else { return false }
            seenKeys.insert(key)
            return true
        }
        self.words = uniqueWords
        wordSequences = uniqueWords
            .map { NamingWordTokenizer.words(in: $0).map { $0.lowercased() } }
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }
    }

    /// The presets: pairs that run together in AppKit, UIKitCore, UIFoundation
    /// and SwiftUICore far more often than either word does alone, and set
    /// phrases of Cocoa.
    public static let presetWords: [String] = [
        "ViewController",
        "GestureRecognizer",
        "DataSource",
        "IndexPath",
        "TraitCollection",
        "HitTest",
        "CornerRadius",
        "SafeArea",
        "ToolTip",
        "KeyPath",
        "RunLoop",
        "TimeZone",
        "UserInfo",
        "PopUp",
        "FirstResponder",
        "LayoutGuide",
        "LineBreak",
        "WhiteSpace",
    ]

    /// The presets less the ones the user removed, plus the words the user
    /// added.
    public static func effective(addedWords: [String], removedPresetWords: [String]) -> NamingCompoundWords {
        let removedKeys = Set(removedPresetWords.map { $0.lowercased() })
        let presets = presetWords.filter { !removedKeys.contains($0.lowercased()) }
        return NamingCompoundWords(words: presets + addedWords)
    }

    /// `words` with every run that spells a compound word joined into one
    /// word, spelled as its parts were.
    public func merging(_ words: [String]) -> [String] {
        guard !wordSequences.isEmpty, words.count >= 2 else { return words }
        let keys = words.map { $0.lowercased() }
        var merged: [String] = []
        var wordIndex = 0
        while wordIndex < words.count {
            let matchedSequence = wordSequences.first { sequence in
                wordIndex + sequence.count <= keys.count && Array(keys[wordIndex ..< wordIndex + sequence.count]) == sequence
            }
            if let matchedSequence {
                merged.append(words[wordIndex ..< wordIndex + matchedSequence.count].joined())
                wordIndex += matchedSequence.count
            } else {
                merged.append(words[wordIndex])
                wordIndex += 1
            }
        }
        return merged
    }
}
