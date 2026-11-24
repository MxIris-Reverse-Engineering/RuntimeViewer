import Foundation
import Semantic
import RuntimeViewerCore
import RuntimeViewerCrossReferences

/// One interface as the content pane shows it: the generator's semantic string, with what the pane looks
/// up by character position — the jump target of a link, the member a line declares — and what the
/// SourceEditor pane draws beside the text. Every index and range is in UTF-16 offsets of `string`, as
/// the text views index it.
///
/// No fonts or colours: RuntimeViewerAppUI themes the text (`attributedString(themedWith:)` there),
/// and a pane that draws the semantic runs itself — SourceEditor — never builds that (proposal
/// `app-core-without-ui-models`).
public struct ContentInterface: Sendable, Identifiable {
    /// Which interface a view reports it has put on screen
    /// (`ContentTextViewModel.Input.interfaceDisplayed`); every interface a view model prepares has an
    /// identifier of its own.
    public struct ID: Hashable, Sendable {
        private let value = UUID()

        init() {}
    }

    /// A jump target over a range of the text.
    public struct Link: Sendable {
        public let range: NSRange
        public let target: RuntimeObject
    }

    /// The member a line of the text declares, over the whole line.
    public struct DeclaredMemberLine: Sendable {
        public let range: NSRange
        public let member: RuntimeMemberReference
    }

    public let id: ID

    /// The object the text describes.
    public let runtimeObject: RuntimeObject

    /// Semantic runs from the generator: what each identifier actually *is*, which no amount of
    /// scanning the text can recover.
    public let semanticString: FrozenSemanticString

    /// Ascending by location, never overlapping.
    public let links: [Link]

    /// Ascending by location, never overlapping.
    public let declaredMemberLines: [DeclaredMemberLine]

    /// How the SourceEditor pane draws the comments of this text; nil when the engine sent no comment
    /// structure with it. The `NSTextView` pane does not read it.
    public let commentDecorations: InterfaceCommentDecorations?

    /// The attached macros this text shows folded, which the SourceEditor pane can expand in place;
    /// empty when the engine sent none. The `NSTextView` pane does not read them.
    public let macroExpansions: [ContentTextViewModel.MacroExpansion]

    /// What the SourceEditor pane says beside each C-imported type this text declares under two
    /// names, ascending by location; empty when the engine sent none. The `NSTextView` pane does not
    /// read them.
    public let cImportedTypeNameNotes: [ContentTextViewModel.CImportedTypeNameNote]

    init(
        id: ID = ID(),
        runtimeObject: RuntimeObject,
        semanticString: FrozenSemanticString,
        links: [Link],
        declaredMemberLines: [DeclaredMemberLine],
        commentDecorations: InterfaceCommentDecorations? = nil,
        macroExpansions: [ContentTextViewModel.MacroExpansion] = [],
        cImportedTypeNameNotes: [ContentTextViewModel.CImportedTypeNameNote] = []
    ) {
        self.id = id
        self.runtimeObject = runtimeObject
        self.semanticString = semanticString
        self.links = links
        self.declaredMemberLines = declaredMemberLines
        self.commentDecorations = commentDecorations
        self.macroExpansions = macroExpansions
        self.cImportedTypeNameNotes = cImportedTypeNameNotes
    }

    /// The text without its semantic runs.
    public var string: String {
        semanticString.string
    }

    // MARK: - Looking Up

    /// The object the token at `characterIndex` links to: the jump target the generator recorded for
    /// it. `nil` off a link and outside the text — AppKit hands the panes the insertion point's index,
    /// which is the text's length after its last character.
    public func linkedRuntimeObject(at characterIndex: Int) -> RuntimeObject? {
        Self.element(of: links, at: characterIndex, range: \.range)?.target
    }

    /// The member the line holding `characterIndex` declares, if it declares one with code; `nil`
    /// elsewhere and outside the text.
    public func declaredMember(at characterIndex: Int) -> RuntimeMemberReference? {
        Self.element(of: declaredMemberLines, at: characterIndex, range: \.range)?.member
    }

    /// The element of `elements` — ascending, non-overlapping ranges — whose range holds `characterIndex`.
    private static func element<Element>(of elements: [Element], at characterIndex: Int, range: KeyPath<Element, NSRange>) -> Element? {
        var lowerIndex = 0
        var upperIndex = elements.count
        while lowerIndex < upperIndex {
            let middleIndex = (lowerIndex + upperIndex) / 2
            let elementRange = elements[middleIndex][keyPath: range]
            if characterIndex < elementRange.location {
                upperIndex = middleIndex
            } else if characterIndex >= NSMaxRange(elementRange) {
                lowerIndex = middleIndex + 1
            } else {
                return elements[middleIndex]
            }
        }
        return nil
    }
}

// MARK: - Preparing

extension ContentInterface {
    /// The interface the pane shows for a fetched one: its text with the tables the pane looks things
    /// up in, the comment decorations and the macro expansions. Runs on the pipeline's background
    /// scheduler; the text can be megabytes.
    static func prepared(from fetchedInterface: ContentTextViewModel.FetchedInterface, id: ID = ID()) -> ContentInterface {
        let semanticString = fetchedInterface.interfaceString
        let runtimeObject = fetchedInterface.runtimeObject
        return ContentInterface(
            id: id,
            runtimeObject: runtimeObject,
            semanticString: semanticString,
            links: links(in: semanticString, of: runtimeObject),
            declaredMemberLines: declaredMemberLines(in: semanticString, of: runtimeObject),
            commentDecorations: fetchedInterface.commentStructure.map {
                InterfaceCommentDecorations(structure: $0, interfaceString: semanticString)
            },
            macroExpansions: ContentTextViewModel.renderedMacroExpansions(of: fetchedInterface),
            cImportedTypeNameNotes: ContentTextViewModel.cImportedTypeNameNotes(of: fetchedInterface)
        )
    }

    /// The jump targets of `semanticString`'s type tokens. A Swift interface links each type-reference
    /// span by its mangled-name identity, so the whole `Module.Type` span links to one target whose
    /// kind comes from its first `.type` token; an Objective-C or C interface has no span identity and
    /// links each type token by its text.
    static func links(in semanticString: FrozenSemanticString, of runtimeObject: RuntimeObject) -> [Link] {
        let linkTargetsByIdentifier: [String: RuntimeObject]
        if case .swift = runtimeObject.kind {
            linkTargetsByIdentifier = swiftLinkTargets(in: semanticString, of: runtimeObject)
        } else {
            linkTargetsByIdentifier = [:]
        }
        var links: [Link] = []
        var utf16Location = 0
        semanticString.enumerateSpans { spanText, type, identifier in
            let range = NSRange(location: utf16Location, length: spanText.utf16.count)
            utf16Location += range.length
            if case .swift = runtimeObject.kind {
                if let identifier, let linkTarget = linkTargetsByIdentifier[identifier] {
                    links.append(Link(range: range, target: linkTarget))
                }
            } else if let targetKind = linkTargetKind(of: type, in: runtimeObject) {
                let tokenString = String(spanText)
                links.append(Link(range: range, target: RuntimeObject(
                    name: tokenString,
                    displayName: tokenString,
                    kind: targetKind,
                    imagePath: runtimeObject.imagePath,
                    children: []
                )))
            }
        }
        return links
    }

    /// One `RuntimeObject` per Swift type-reference span, keyed by the span's mangled-name identity. A
    /// span becomes a jump target only when it contains a `.type` token (so plain `.standard` spans — a
    /// typealias reference — get no link); its `name` is the mangled identity the engine resolves across
    /// images, its `displayName` the fully printed qualified name.
    private static func swiftLinkTargets(in semanticString: FrozenSemanticString, of runtimeObject: RuntimeObject) -> [String: RuntimeObject] {
        var kindByIdentifier: [String: RuntimeObjectKind] = [:]
        var displayNameByIdentifier: [String: String] = [:]
        semanticString.enumerateSpans { spanText, type, identifier in
            guard let identifier else { return }
            displayNameByIdentifier[identifier, default: ""] += spanText
            if kindByIdentifier[identifier] == nil, let kind = linkTargetKind(of: type, in: runtimeObject) {
                kindByIdentifier[identifier] = kind
            }
        }
        var linkTargets: [String: RuntimeObject] = [:]
        linkTargets.reserveCapacity(kindByIdentifier.count)
        for (identifier, kind) in kindByIdentifier {
            linkTargets[identifier] = RuntimeObject(
                name: identifier,
                displayName: displayNameByIdentifier[identifier] ?? identifier,
                kind: kind,
                imagePath: runtimeObject.imagePath,
                children: []
            )
        }
        return linkTargets
    }

    /// The kind of object a `.type` token names in an interface of `runtimeObject`'s language.
    private static func linkTargetKind(of type: SemanticType, in runtimeObject: RuntimeObject) -> RuntimeObjectKind? {
        guard case .type(let kind, _) = type else { return nil }
        switch runtimeObject.kind {
        case .c, .objc:
            switch kind {
            case .class: return .objc(.type(.class))
            case .protocol: return .objc(.type(.protocol))
            case .struct: return .c(.struct)
            case .other: return .c(.union)
            default: return nil
            }
        case .swift:
            switch kind {
            case .enum: return .swift(.type(.enum))
            case .struct: return .swift(.type(.struct))
            case .class: return .swift(.type(.class))
            case .protocol: return .swift(.type(.protocol))
            default: return nil
            }
        case .cPlusPlus:
            // A C++ interface spells every class and namespace it names in full
            // (`CPlusPlusInterfacePrinter`), so the token's text is the name the
            // engine looks the object up by.
            switch kind {
            case .class: return .cPlusPlus(.class)
            case .other: return .cPlusPlus(.namespace)
            default: return nil
            }
        }
    }

    /// Every line of the text that declares a member with code, which the right-click menu and the
    /// insertion point read as a link names a type. Which line declares what is read the way the Find
    /// corpus locates members on their lines.
    static func declaredMemberLines(in semanticString: FrozenSemanticString, of runtimeObject: RuntimeObject) -> [DeclaredMemberLine] {
        let interface = RuntimeObjectInterface(object: runtimeObject, interfaceString: semanticString)
        let membersByLineNumber = interface.declaredMembersByLineNumber()
            .filter { FindCrossReferenceRoot.memberKindsWithCode.contains($0.value.kind) }
        guard !membersByLineNumber.isEmpty else { return [] }
        let text = semanticString.string as NSString
        var declaredMemberLines: [DeclaredMemberLine] = []
        var lineNumber = 1
        var lineStart = 0
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            if let declaredMember = membersByLineNumber[lineNumber] {
                let member = RuntimeMemberReference(object: runtimeObject, name: declaredMember.name, kind: declaredMember.kind, isStatic: declaredMember.isStatic)
                declaredMemberLines.append(DeclaredMemberLine(range: lineRange, member: member))
            }
            lineNumber += 1
            lineStart = NSMaxRange(lineRange)
        }
        return declaredMemberLines
    }
}
