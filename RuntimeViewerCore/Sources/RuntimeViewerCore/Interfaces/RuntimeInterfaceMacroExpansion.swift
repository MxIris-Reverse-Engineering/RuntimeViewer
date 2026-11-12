import Foundation
public import Semantic

/// An attached macro an interface printed folded shows — `@Observation.Observable` on a class
/// compiled from `@Observable` — with where its attribute is and the declarations it generated, in
/// the places Xcode's Expand Macro shows them: after each tracked property, inside the type's body
/// above its closing brace, and after the type.
///
/// The engine sends these when the request asks for them
/// (`RuntimeObjectInterface.GenerationOptions.marksAttachedMacros`). MachOSwiftSection marks each
/// attribute and each tracked property's declaration it prints with an annotation region of its own
/// kind, and prints the expansion in parts
/// (`SwiftDeclarationPrinter.printMacroExpansionParts(of:attachedTo:)`), under the same configuration
/// as the interface; RuntimeViewer only places them.
public struct RuntimeInterfaceMacroExpansion: Codable, Sendable {
    /// The macro as its attribute names it, `Observation.Observable`.
    public let macroName: String

    /// Where the attribute is in the interface's text, in UTF-8 offsets, as the comment structure
    /// counts them.
    public let attributeUTF8Range: Range<Int>

    /// The declarations the macro generated, a part for each place they go, in text order.
    public let parts: [Part]

    public init(macroName: String, attributeUTF8Range: Range<Int>, parts: [Part]) {
        self.macroName = macroName
        self.attributeUTF8Range = attributeUTF8Range
        self.parts = parts
    }

    /// One place of the expansion: what it hangs at in the interface's text, on which side of that
    /// line, and the declarations.
    public struct Part: Codable, Sendable {
        /// Which side of its anchor's line a part goes on.
        public enum Placement: String, Codable, Sendable {
            /// Between the anchor's line and the next: after a tracked property's declaration, or
            /// after the type's closing brace.
            case belowLine
            /// Between the anchor's line and the one before: inside the type's body, above its
            /// closing brace.
            case aboveLine
        }

        /// What the part hangs at, in UTF-8 offsets of the interface's text: a tracked property's
        /// declaration, or the line of the type's closing brace.
        public let anchorUTF8Range: Range<Int>

        public let placement: Placement

        /// The declarations, without indentation of their own: a viewer indents them from the line
        /// they go at, as Xcode indents an expanded macro.
        public let content: FrozenSemanticString

        public init(anchorUTF8Range: Range<Int>, placement: Placement, content: FrozenSemanticString) {
            self.anchorUTF8Range = anchorUTF8Range
            self.placement = placement
            self.content = content
        }
    }
}
