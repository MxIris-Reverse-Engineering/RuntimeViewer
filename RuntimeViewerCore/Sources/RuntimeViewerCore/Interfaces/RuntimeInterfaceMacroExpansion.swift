import Foundation
public import Semantic

/// An attached macro an interface printed folded shows — `@Observation.Observable` on a class
/// compiled from `@Observable` — with where its attribute is and what it wrote, in the places
/// Xcode's Expand Macro shows them: above each tracked property the `@ObservationTracked` it puts
/// there, inside the type's body above its closing brace, and after the type. What such an
/// attribute expands to in turn — the property's accessors and storage, below its declaration —
/// is a nested expansion of the part that holds it (`Part.nestedExpansions`), as Xcode expands it
/// from inside the expanded text.
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
    /// counts them. For an expansion in a part's `nestedExpansions`, where the attribute is in that
    /// part's `content` instead.
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

        /// The macros `content` attaches, each with what it expands to — which Xcode expands from
        /// inside the expanded text. `@Observable`'s part for a tracked property is the
        /// `@ObservationTracked` it puts on the declaration, and that attribute expands to the
        /// property's accessors and storage. Each one's attribute range is in `content`, and its
        /// parts hang in the interface's text like every other part. Empty for a part that
        /// attaches nothing.
        public let nestedExpansions: [RuntimeInterfaceMacroExpansion]

        public init(anchorUTF8Range: Range<Int>, placement: Placement, content: FrozenSemanticString, nestedExpansions: [RuntimeInterfaceMacroExpansion] = []) {
            self.anchorUTF8Range = anchorUTF8Range
            self.placement = placement
            self.content = content
            self.nestedExpansions = nestedExpansions
        }
    }
}
