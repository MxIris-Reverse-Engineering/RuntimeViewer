import Foundation
import RuntimeViewerCore
import Semantic

/// What the SourceEditor content panes — the macOS one and the iOS one — hand the editor along with
/// an interface's text: the language to parse it as, and the semantic runs that correct the parse.
///
/// The framework parses plain text and cannot tell what an identifier is; RuntimeViewer can, because
/// the text was rendered from runtime metadata. The runs carry that knowledge across, as the node
/// types `SemanticNodeTypeAdjuster` in the bridge retypes the parse to.
public enum SourceEditorSourceConversion {
    /// The language the editor highlights an interface as: the language it is asked for in, or the
    /// object's own — an Objective-C object's Generated Interface is Swift. C++ is `cpp`, which the
    /// bridge maps to the reconstruction's C++ language. An identifier the bridge has no language for
    /// leaves the whole interface uncoloured: without a language the data source has no language
    /// service to retype the semantic runs on.
    public static func languageIdentifier(for kind: RuntimeObjectKind, interfaceLanguage: RuntimeInterfaceLanguage?) -> String {
        if interfaceLanguage == .swift {
            return "swift"
        }
        return switch kind {
        case .swift: "swift"
        case .objc, .c: "objc"
        case .cPlusPlus: "cpp"
        }
    }

    /// Walks the generator's semantic runs into the two parallel arrays the bridge takes.
    ///
    /// The node type names are the same strings as the theme's syntax keys, so
    /// `SourceEditorThemeConversion`'s table serves both directions — it maps a `SemanticType` to a
    /// key for colouring, and to a node type name here.
    ///
    /// Offsets are accumulated in UTF-16 because that is what the editor, `NSRange` and
    /// `NSAttributedString` all index by; counting `Character`s would drift on anything outside the
    /// basic plane. An empty span gets no run.
    public static func semanticRuns(of semanticString: FrozenSemanticString) -> (ranges: [NSValue], nodeTypeNames: [String]) {
        var ranges: [NSValue] = []
        var nodeTypeNames: [String] = []
        var location = 0

        semanticString.enumerateSpans { spanText, semanticType, _ in
            let length = spanText.utf16.count
            defer { location += length }
            guard length > 0 else { return }
            ranges.append(NSValue(range: NSRange(location: location, length: length)))
            nodeTypeNames.append(SourceEditorThemeConversion.syntaxColorKey(for: semanticType))
        }

        return (ranges, nodeTypeNames)
    }
}
