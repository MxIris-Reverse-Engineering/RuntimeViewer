import Foundation

/// Splits a name into the words the naming word cloud counts.
///
/// Surrounding underscores go, every other character that is neither a
/// letter nor a digit separates words (`_`, `:`, `.`), and case changes do
/// too. A run of capitals is one word — an acronym — except for its last
/// capital when a lowercase letter follows, which starts the next word
/// (`URLSession` → `URL`, `Session`); digits stay with the letters before
/// them (`UTF8String` → `UTF8`, `String`). Words of a single letter and
/// words of digits alone are dropped.
public enum NamingWordTokenizer {
    /// The words of `name` as spelled, in order, before compound words are
    /// merged or common words dropped.
    public static func words(in name: String) -> [String] {
        rawTokens(in: name).filter(isCountedWord)
    }

    /// The words `name` is counted under: split, compound words merged
    /// when `compoundWords` is given, common words dropped when
    /// `ignoresCommonWords` is on.
    public static func countedWords(in name: String, compoundWords: NamingCompoundWords?, ignoresCommonWords: Bool) -> [String] {
        var words = words(in: name)
        if let compoundWords {
            words = compoundWords.merging(words)
        }
        if ignoresCommonWords {
            words = words.filter { !commonWords.contains($0.lowercased()) }
        }
        return words
    }

    /// Function words that carry no naming habit of their own.
    public static let commonWords: Set<String> = [
        "and", "as", "at", "by", "for", "from", "in", "into", "of", "on", "or", "the", "to", "with",
    ]

    /// How a word is shown: an acronym as spelled, any other word with its
    /// first letter capitalized — or, for the first words of methods, the
    /// whole word in lowercase.
    public static func displayedWord(_ spelling: String, isLowercased: Bool) -> String {
        if isLowercased {
            return spelling.lowercased()
        }
        if isAcronym(spelling) {
            return spelling
        }
        return spelling.prefix(1).uppercased() + spelling.dropFirst()
    }

    /// At least two letters, every one of them a capital; digits may follow.
    public static func isAcronym(_ spelling: String) -> Bool {
        let letters = spelling.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    // MARK: - Splitting

    private static func isCountedWord(_ word: String) -> Bool {
        let letterCount = word.count(where: \.isLetter)
        // A single letter, or digits alone.
        return letterCount >= 1 && word.count >= 2
    }

    private static func rawTokens(in name: String) -> [String] {
        let characters = Array(name)
        var tokens: [String] = []
        var currentToken = ""

        func endToken() {
            if !currentToken.isEmpty {
                tokens.append(currentToken)
                currentToken = ""
            }
        }

        for (characterIndex, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                endToken()
                continue
            }
            guard let previousCharacter = currentToken.last else {
                currentToken.append(character)
                continue
            }
            let nextCharacter = characterIndex + 1 < characters.count ? characters[characterIndex + 1] : nil
            if character.isNumber {
                // Digits stay with the word before them.
                currentToken.append(character)
            } else if character.isUppercase {
                let startsWord = previousCharacter.isLowercase
                    || previousCharacter.isNumber
                    // The last capital of a run, followed by lowercase, starts the next word.
                    || (previousCharacter.isUppercase && nextCharacter?.isLowercase == true)
                if startsWord {
                    endToken()
                }
                currentToken.append(character)
            } else {
                if previousCharacter.isNumber {
                    endToken()
                }
                currentToken.append(character)
            }
        }
        endToken()
        return tokens
    }
}
