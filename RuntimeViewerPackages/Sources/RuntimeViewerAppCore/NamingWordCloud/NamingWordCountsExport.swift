import Foundation
import RuntimeViewerCore

/// The naming word cloud's word counts as files: CSV with each word and its
/// count, JSON with the names behind each count as well. Both hold every
/// counted word, not only the ones the cloud draws.
public enum NamingWordCountsExport {
    /// What the counts were made from, which the JSON records.
    public struct Context: Hashable, Sendable {
        public var imagePath: String
        public var measure: NamingWordMeasure
        public var memberGroup: NamingMemberGroup?
        /// The class prefix taken off type names, `nil` when none was.
        public var removedTypePrefix: String?
        public var ignoresCommonWords: Bool
        public var mergesCompoundWords: Bool

        public init(imagePath: String, measure: NamingWordMeasure, memberGroup: NamingMemberGroup?, removedTypePrefix: String?, ignoresCommonWords: Bool, mergesCompoundWords: Bool) {
            self.imagePath = imagePath
            self.measure = measure
            self.memberGroup = memberGroup
            self.removedTypePrefix = removedTypePrefix
            self.ignoresCommonWords = ignoresCommonWords
            self.mergesCompoundWords = mergesCompoundWords
        }
    }

    /// `word,count`, one word a line, the most common first. Names stay out:
    /// a common member word stands for thousands of them, past the 32,767
    /// characters a spreadsheet cell holds.
    public static func csv(of wordCounts: [NamingWordCount]) -> String {
        var lines = ["word,count"]
        lines += wordCounts.map { "\(csvField($0.word)),\($0.count)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The image, the measure, its switches, and each word with its count,
    /// category and names — a type with its kind, a member with its kind and
    /// the type that declares it — the most common first.
    public static func json(of wordCounts: [NamingWordCount], context: Context) throws -> Data {
        let document = Document(
            image: URL(fileURLWithPath: context.imagePath).deletingPathExtension().lastPathComponent,
            imagePath: context.imagePath,
            measure: context.measure.rawValue,
            memberGroup: context.measure == .memberWords ? context.memberGroup?.rawValue : nil,
            removedTypePrefix: context.removedTypePrefix,
            ignoresCommonWords: context.ignoresCommonWords,
            mergesCompoundWords: context.mergesCompoundWords,
            words: wordCounts.map { wordCount in
                Word(
                    word: wordCount.word,
                    count: wordCount.count,
                    category: wordCount.category.rawValue,
                    names: wordCount.usages.map(Name.init)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    /// A CSV field, quoted when it holds a comma, a quote or a line break,
    /// with its quotes doubled.
    static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private struct Document: Encodable {
        let image: String
        let imagePath: String
        let measure: String
        let memberGroup: String?
        let removedTypePrefix: String?
        let ignoresCommonWords: Bool
        let mergesCompoundWords: Bool
        let words: [Word]
    }

    private struct Word: Encodable {
        let word: String
        let count: Int
        let category: String
        let names: [Name]
    }

    private struct Name: Encodable {
        let name: String
        let kind: String
        /// The type that declares a member; absent for a type.
        let type: String?

        init(_ usage: NamingWordUsage) {
            switch usage {
            case .type(let object):
                name = object.displayName
                type = nil
            case .member(let member, let object):
                name = member.name
                type = object.displayName
            }
            kind = usage.kindName
        }
    }
}
