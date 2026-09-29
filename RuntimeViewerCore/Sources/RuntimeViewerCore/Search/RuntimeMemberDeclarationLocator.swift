import Foundation
import Semantic

/// Aligns a structured member list with the interface the corpus printed,
/// so every member the sections know about also knows the line it is
/// declared on.
///
/// The structures and the text come from the same definitions, printed in
/// the same pass, so they agree on names. The alignment is by name per line:
/// one walk over the frozen spans records, for each line, the declaration
/// names on it — property, field and variable names as `.member(.declaration)`
/// or `.variable` spans, selector pieces (without their colons) and function
/// names as `.function(.declaration)` spans, `subscript` / `init` as keywords — and each
/// member then takes the first not-yet-claimed line carrying its name.
/// Overloads share a name and are claimed in printed order, which matches the
/// order the definitions list them. A member with no line stays unlocated;
/// it is still searchable and still reaches its type.
enum RuntimeMemberDeclarationLocator {
    /// One printed line's declaration evidence.
    private struct Line {
        var text = ""
        /// Names from `.member(.declaration)` and `.variable` spans.
        var names: [String] = []
        /// Pieces from `.function(.declaration)` spans, in order: for an
        /// Objective-C method the selector segments, for a Swift function
        /// the base name followed by its parameter labels.
        var functionPieces: [String] = []
        var keywords: [String] = []
    }

    static func locate(_ members: [RuntimeMemberDeclaration], in interface: FrozenSemanticString) -> [RuntimeMemberDeclaration] {
        guard !members.isEmpty else { return members }
        let lines = lines(of: interface)
        var lineNumbersByKey = lineNumbersByKey(from: lines)

        return members.map { member in
            for key in keys(for: member) {
                guard var lineNumbers = lineNumbersByKey[key], !lineNumbers.isEmpty else { continue }
                let lineNumber = lineNumbers.removeFirst()
                lineNumbersByKey[key] = lineNumbers
                let declarationText = lines[lineNumber - 1].text.trimmingCharacters(in: .whitespaces)
                return member.located(at: lineNumber, declarationText: declarationText)
            }
            return member
        }
    }

    // MARK: - Line evidence

    private static func lines(of interface: FrozenSemanticString) -> [Line] {
        var lines: [Line] = [Line()]
        interface.enumerateSpans { spanText, type, _ in
            // A span can carry line breaks — a multi-line comment, the
            // printer's paragraph separators — so it is split and its pieces
            // land on consecutive lines. Declaration evidence is only taken
            // from a piece that is the whole span: a name never straddles a
            // line break.
            let pieces = spanText.split(separator: "\n", omittingEmptySubsequences: false)
            for (pieceIndex, piece) in pieces.enumerated() {
                if pieceIndex > 0 {
                    lines.append(Line())
                }
                guard !piece.isEmpty else { continue }
                lines[lines.count - 1].text += piece
                guard pieces.count == 1 else { continue }
                let token = String(piece)
                switch type {
                case .member(.declaration), .variable:
                    lines[lines.count - 1].names.append(token)
                case .function(.declaration):
                    lines[lines.count - 1].functionPieces.append(token)
                case .keyword:
                    lines[lines.count - 1].keywords.append(token)
                default:
                    break
                }
            }
        }
        return lines
    }

    private static func lineNumbersByKey(from lines: [Line]) -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            for name in line.names {
                result[nameKey(name), default: []].append(lineNumber)
            }
            if let firstPiece = line.functionPieces.first {
                // A Swift function's base name is its first piece. An
                // Objective-C selector is every piece joined with the colons
                // the renderer prints as plain text between them — so a
                // one-piece line registers both `name` (a method without
                // arguments, or a Swift function) and `name:` (a method with
                // one argument).
                result[functionKey(firstPiece), default: []].append(lineNumber)
                result[functionKey(line.functionPieces.joined(separator: ":") + ":"), default: []].append(lineNumber)
            }
            for keyword in line.keywords where keyword == "subscript" || keyword == "init" {
                result[keywordKey(keyword), default: []].append(lineNumber)
            }
        }
        return result
    }

    // MARK: - Keys

    private static func nameKey(_ name: String) -> String { "n:" + name }
    private static func functionKey(_ name: String) -> String { "f:" + name }
    private static func keywordKey(_ keyword: String) -> String { "k:" + keyword }

    /// The keys a member may be declared under, most specific first.
    private static func keys(for member: RuntimeMemberDeclaration) -> [String] {
        switch member.kind {
        case .objcMethod:
            return [functionKey(member.name)]
        case .objcProperty, .objcIvar, .swiftField, .swiftEnumCase, .swiftVariable:
            return [nameKey(member.name), functionKey(member.name)]
        case .swiftFunction:
            return [functionKey(member.name), nameKey(member.name)]
        case .swiftSubscript:
            return [keywordKey("subscript")]
        case .swiftInitializer:
            return [keywordKey("init"), functionKey("init")]
        }
    }
}
