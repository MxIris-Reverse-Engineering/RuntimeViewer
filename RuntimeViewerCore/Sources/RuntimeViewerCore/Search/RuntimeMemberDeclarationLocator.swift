import Foundation
import Semantic

/// Aligns a structured member list with the interface the corpus printed,
/// so every member the sections know about also knows the line it is
/// declared on.
///
/// The structures and the text come from the same definitions, printed in
/// the same pass, so they agree on names — but a name alone does not say
/// what a line declares. An Objective-C property and the ivar behind it, a
/// bitfield of an anonymous struct and the property that reads it, a class
/// property and an instance property, an initializer's argument label and a
/// static function all share names. So a member is matched by its
/// declaration key — kind, whether it is static, and name — and each kind of
/// key is read off one kind of span on one kind of line, the way the
/// renderers print them (MachOObjCSection's `ObjCDump+SemanticString.swift`,
/// the member printers of MachOSwiftSection's `SwiftDeclarationPrinter`):
///
/// - Objective-C property: the `.member(.declaration)` span of an
///   `@property` line, static when the line carries the `class` attribute.
/// - Objective-C ivar: a `.variable` span directly inside the ivar braces an
///   `@interface` line opens — not in a struct or union expanded inline
///   there, and not in a struct a property's or a method's type expands to.
/// - Objective-C method: the selector a line starting with `-` or `+`
///   spells, each `.function(.declaration)` piece with the colon printed
///   after it; static for `+`.
/// - Swift field, enum case and variable: a `.member(.declaration)` or
///   `.variable` span, static when the line carries `static` or `class`.
/// - Swift function: what follows `func` — a `.function(.declaration)`
///   span, or the operator an operator function prints as plain text. The
///   argument labels after it are `.function(.declaration)` spans too, and
///   are not names.
/// - Swift initializer and subscript: the keyword alone. Their argument
///   labels must not pass for the function of that name either.
///
/// Each member takes the first not-yet-claimed line carrying its key, and a
/// member printed twice is claimed once: when the two verdicts on
/// Objective-C evidence give a member different attributes, the corpus
/// prints it under each, the second right where the first ends — on the
/// same line, which carries each of its keys once, or, for a variable or a
/// subscript, on the first one's closing-brace line, which declares nothing
/// of its own. Overloads share a key and are claimed in printed order. A
/// member with no line stays unlocated; it is still searchable and still
/// reaches its type.
///
/// The lines of the object's nested types are not the object's: a type
/// prints its nested types above its own members, and their declarations
/// share names with its own often enough — the cases of a `Codable` type's
/// synthesized `CodingKeys` are named after its fields. The caller passes
/// those blocks in, and no member is located inside them.
///
/// Only the line number is recorded. A corpus entry reads the declaration
/// line of a member it shows back out of its interface
/// (`RuntimeInterfaceCorpusEntry.displayedMember(at:)`), so no line is
/// copied here.
enum RuntimeMemberDeclarationLocator {
    /// `excludedUTF8Ranges` — ascending, non-overlapping — are the blocks of
    /// `interface` no member may be located in.
    static func locate(_ members: [RuntimeMemberDeclaration], in interface: FrozenSemanticString, excludingUTF8Ranges excludedUTF8Ranges: [Range<Int>] = []) -> [RuntimeMemberDeclaration] {
        guard !members.isEmpty else { return members }
        var walk = DeclarationWalk(text: interface.text, excludedUTF8Ranges: excludedUTF8Ranges)
        interface.enumerateSpans { spanText, type, _ in
            walk.read(spanText, of: type)
        }
        let lineNumbersByKey = walk.finish()

        var claimedCountByKey: [DeclarationKey: Int] = [:]
        return members.map { member in
            let key = DeclarationKey(member)
            guard let lineNumbers = lineNumbersByKey[key] else { return member }
            let claimedCount = claimedCountByKey[key, default: 0]
            guard claimedCount < lineNumbers.count else { return member }
            claimedCountByKey[key] = claimedCount + 1
            return member.located(at: lineNumbers[claimedCount], declarationText: member.name)
        }
    }

    // MARK: - Keys

    /// What a member is declared as, the way a line spells it.
    private struct DeclarationKey: Hashable {
        enum Kind: Hashable {
            case objectiveCProperty
            case objectiveCInstanceVariable
            case objectiveCMethod
            /// A Swift field, enum case or variable: the line spells only
            /// its name.
            case swiftNamedValue
            case swiftFunction
            case swiftInitializer
            case swiftSubscript
        }

        let kind: Kind
        let isStatic: Bool
        let name: String

        init(kind: Kind, isStatic: Bool, name: String) {
            self.kind = kind
            self.isStatic = isStatic
            self.name = name
        }

        /// The one key `member` is declared under. The sections list an
        /// initializer as static, which its line does not say, so that flag
        /// is not part of an initializer's key; an ivar has no class form.
        init(_ member: RuntimeMemberDeclaration) {
            switch member.kind {
            case .objcProperty:
                self.init(kind: .objectiveCProperty, isStatic: member.isStatic, name: member.name)
            case .objcIvar:
                self.init(kind: .objectiveCInstanceVariable, isStatic: false, name: member.name)
            case .objcMethod:
                self.init(kind: .objectiveCMethod, isStatic: member.isStatic, name: member.name)
            case .swiftField, .swiftEnumCase, .swiftVariable:
                self.init(kind: .swiftNamedValue, isStatic: member.isStatic, name: member.name)
            case .swiftFunction:
                self.init(kind: .swiftFunction, isStatic: member.isStatic, name: member.name)
            case .swiftInitializer:
                self.init(kind: .swiftInitializer, isStatic: false, name: "init")
            case .swiftSubscript:
                self.init(kind: .swiftSubscript, isStatic: member.isStatic, name: "subscript")
            }
        }
    }

    /// The keywords that say what a line declares.
    private struct DeclarationKeywords: OptionSet {
        let rawValue: UInt8

        /// `@interface`, whose line opens an Objective-C class's ivar braces.
        static let objectiveCInterface = DeclarationKeywords(rawValue: 1 << 0)
        /// `@property`.
        static let objectiveCProperty = DeclarationKeywords(rawValue: 1 << 1)
        /// `class`: an Objective-C class property's attribute, a Swift
        /// overridable class member's modifier.
        static let classModifier = DeclarationKeywords(rawValue: 1 << 2)
        /// `static`.
        static let staticModifier = DeclarationKeywords(rawValue: 1 << 3)
        /// `func`.
        static let function = DeclarationKeywords(rawValue: 1 << 4)
        /// `init`.
        static let initializer = DeclarationKeywords(rawValue: 1 << 5)
        /// `subscript`.
        static let `subscript` = DeclarationKeywords(rawValue: 1 << 6)

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// The keyword `token` is, or none.
        init(keyword token: Substring) {
            switch token {
            case "@interface": self = .objectiveCInterface
            case "@property": self = .objectiveCProperty
            case "class": self = .classModifier
            case "static": self = .staticModifier
            case "func": self = .function
            case "init": self = .initializer
            case "subscript": self = .subscript
            default: self = []
            }
        }
    }

    /// One printed line's declaration evidence.
    private struct LineEvidence {
        var keywords: DeclarationKeywords = []
        /// Names from `.member(.declaration)` spans.
        var memberDeclarationNames: [String] = []
        /// Names from `.variable` spans directly inside an `@interface`'s
        /// ivar braces.
        var instanceVariableNames: [String] = []
        /// Names from every other `.variable` span.
        var variableNames: [String] = []
        /// The Objective-C selector the line spells, if it is a method: each
        /// `.function(.declaration)` piece, with the colon the renderer
        /// prints after it as plain text.
        var selector = ""
        /// Whether the line has a `.function(.declaration)` span at all.
        var hasFunctionDeclaration = false
        /// What follows the line's first `func`: a Swift function's base
        /// name, or an operator.
        var functionBaseName: String?
    }

    // MARK: - Line evidence

    /// One pass over an interface's spans, line by line, collecting the keys
    /// each line declares. The lines are those of the interface's
    /// `RuntimeInterfaceLineTable`; a span is placed on the line it starts
    /// on.
    private struct DeclarationWalk {
        private let text: String

        private let lineTable: RuntimeInterfaceLineTable

        private let excludedUTF8Ranges: [Range<Int>]

        private var excludedRangeIndex = 0

        /// UTF-8 offset of the next span.
        private var utf8Offset = 0

        /// The line the walk is on, 0-based.
        private var lineIndex = 0

        private var line = LineEvidence()

        /// Braces opened and not yet closed, outside comments.
        private var braceDepth = 0

        /// Whether the outermost open brace is the one an `@interface` line
        /// opens its ivars with.
        private var isInsideInstanceVariableBraces = false

        /// Set by a `.function(.declaration)` span: the colon of a selector
        /// piece is the first character of the span after it.
        private var isAwaitingSelectorColon = false

        /// Set by `func`: the span after the space that follows it names the
        /// function.
        private var isAwaitingFunctionBaseName = false

        private var lineNumbersByKey: [DeclarationKey: [Int]] = [:]

        init(text: String, excludedUTF8Ranges: [Range<Int>]) {
            self.text = text
            self.lineTable = RuntimeInterfaceLineTable(text)
            self.excludedUTF8Ranges = excludedUTF8Ranges
        }

        mutating func read(_ spanText: Substring, of type: SemanticType) {
            let spanStartOffset = utf8Offset
            utf8Offset += spanText.utf8.count
            while lineIndex + 1 < lineTable.lineCount, lineTable.lineStartOffsets[lineIndex + 1] <= spanStartOffset {
                finishLine()
            }
            let nextLineStartOffset = lineIndex + 1 < lineTable.lineCount ? lineTable.lineStartOffsets[lineIndex + 1] : Int.max

            if isAwaitingSelectorColon {
                isAwaitingSelectorColon = false
                if spanText.first == ":" {
                    line.selector += ":"
                }
            }
            if type != .comment {
                countBraces(in: spanText, startingAt: spanStartOffset, nextLineStartOffset: nextLineStartOffset)
            }
            // A span that reaches into a later line — a multi-line comment,
            // the printer's line breaks and indentation — declares nothing:
            // a name never straddles a line break.
            guard utf8Offset < nextLineStartOffset else {
                isAwaitingFunctionBaseName = false
                return
            }
            if isAwaitingFunctionBaseName {
                readFunctionBaseName(in: spanText, of: type)
            }
            switch type {
            case .keyword:
                let keywords = DeclarationKeywords(keyword: spanText)
                line.keywords.formUnion(keywords)
                if keywords.contains(.function), line.functionBaseName == nil {
                    isAwaitingFunctionBaseName = true
                }
            case .member(.declaration):
                line.memberDeclarationNames.append(String(spanText))
            case .variable:
                if isInsideInstanceVariableBraces, braceDepth == 1 {
                    line.instanceVariableNames.append(String(spanText))
                } else {
                    line.variableNames.append(String(spanText))
                }
            case .function(.declaration):
                line.selector += spanText
                line.hasFunctionDeclaration = true
                isAwaitingSelectorColon = true
            default:
                break
            }
        }

        /// The line numbers of every key, each list ascending.
        mutating func finish() -> [DeclarationKey: [Int]] {
            finishLine()
            return lineNumbersByKey
        }

        /// `func` is followed by a space and then by the function's base
        /// name — or, for an operator function, by the operator as plain
        /// text, which the space may share a span with.
        private mutating func readFunctionBaseName(in spanText: Substring, of type: SemanticType) {
            if case .function(.declaration) = type {
                line.functionBaseName = String(spanText)
                isAwaitingFunctionBaseName = false
                return
            }
            let afterSpaces = spanText.drop(while: { $0 == " " })
            guard !afterSpaces.isEmpty else { return }
            isAwaitingFunctionBaseName = false
            guard type == .standard else { return }
            // The printer writes the operator and a space in one piece.
            let operatorName = afterSpaces.prefix(while: { $0 != " " })
            if operatorName.first != "(" {
                line.functionBaseName = String(operatorName)
            }
        }

        /// Keeps `braceDepth` and whether the walk is inside an
        /// `@interface`'s ivar braces. Those are opened on the `@interface`
        /// line itself; a brace past the line break of a span is on a later
        /// line, which no keyword has reached yet.
        private mutating func countBraces(in spanText: Substring, startingAt spanStartOffset: Int, nextLineStartOffset: Int) {
            for (byteIndex, byte) in spanText.utf8.enumerated() {
                if byte == UInt8(ascii: "{") {
                    if braceDepth == 0 {
                        isInsideInstanceVariableBraces = spanStartOffset + byteIndex < nextLineStartOffset && line.keywords.contains(.objectiveCInterface)
                    }
                    braceDepth += 1
                } else if byte == UInt8(ascii: "}") {
                    braceDepth = max(0, braceDepth - 1)
                    if braceDepth == 0 {
                        isInsideInstanceVariableBraces = false
                    }
                }
            }
        }

        /// Registers the keys of the line the walk is on, unless it lies in
        /// an excluded block, and moves to the next line.
        private mutating func finishLine() {
            defer {
                line = LineEvidence()
                lineIndex += 1
            }
            let lineStartOffset = lineTable.lineStartOffsets[lineIndex]
            while excludedRangeIndex < excludedUTF8Ranges.count, excludedUTF8Ranges[excludedRangeIndex].upperBound <= lineStartOffset {
                excludedRangeIndex += 1
            }
            if excludedRangeIndex < excludedUTF8Ranges.count, excludedUTF8Ranges[excludedRangeIndex].contains(lineStartOffset) {
                return
            }
            for key in declarationKeys(of: line, firstByte: firstNonBlankByte(ofLine: lineIndex)) {
                lineNumbersByKey[key, default: []].append(lineIndex + 1)
            }
        }

        private func firstNonBlankByte(ofLine lineIndex: Int) -> UInt8? {
            let lineRange = lineTable.lineUTF8Range(at: lineIndex)
            let bytes = text.utf8
            var byteIndex = bytes.index(bytes.startIndex, offsetBy: lineRange.lowerBound)
            for _ in lineRange {
                let byte = bytes[byteIndex]
                if byte != UInt8(ascii: " "), byte != UInt8(ascii: "\t") {
                    return byte
                }
                byteIndex = bytes.index(after: byteIndex)
            }
            return nil
        }

        /// Every key `line` declares, each once. Keys of both languages are
        /// read off every line: a member only ever looks for keys of its own
        /// kind, so an Objective-C entry's lines never answer a Swift member.
        private func declarationKeys(of line: LineEvidence, firstByte: UInt8?) -> Set<DeclarationKey> {
            var keys: Set<DeclarationKey> = []

            if line.keywords.contains(.objectiveCProperty) {
                let isClassProperty = line.keywords.contains(.classModifier)
                for name in line.memberDeclarationNames {
                    keys.insert(DeclarationKey(kind: .objectiveCProperty, isStatic: isClassProperty, name: name))
                }
            }
            for name in line.instanceVariableNames {
                keys.insert(DeclarationKey(kind: .objectiveCInstanceVariable, isStatic: false, name: name))
            }
            if line.hasFunctionDeclaration, firstByte == UInt8(ascii: "-") || firstByte == UInt8(ascii: "+") {
                keys.insert(DeclarationKey(kind: .objectiveCMethod, isStatic: firstByte == UInt8(ascii: "+"), name: line.selector))
            }

            // A Swift declaration that follows a closing brace on its line is
            // the second rendering of the member above it. An Objective-C
            // line can start with one and still declare an ivar: the one of
            // a struct type expanded inline, `} _flags;`.
            guard firstByte != UInt8(ascii: "}") else { return keys }

            let isStaticSwiftMember = line.keywords.contains(.staticModifier) || line.keywords.contains(.classModifier)
            for name in line.memberDeclarationNames + line.variableNames {
                keys.insert(DeclarationKey(kind: .swiftNamedValue, isStatic: isStaticSwiftMember, name: name))
            }
            if let functionBaseName = line.functionBaseName {
                keys.insert(DeclarationKey(kind: .swiftFunction, isStatic: isStaticSwiftMember, name: functionBaseName))
            }
            if line.keywords.contains(.initializer) {
                keys.insert(DeclarationKey(kind: .swiftInitializer, isStatic: false, name: "init"))
            }
            if line.keywords.contains(.subscript) {
                keys.insert(DeclarationKey(kind: .swiftSubscript, isStatic: isStaticSwiftMember, name: "subscript"))
            }
            return keys
        }
    }
}
