import Foundation
public import Semantic

/// An attached macro an interface printed folded shows — `@Observation.Observable` on a class
/// compiled from `@Observable` — with where its attribute is and the declarations it generated, for
/// a viewer that shows them below the attribute the way Xcode shows an expanded macro.
///
/// The engine sends these when the request asks for them
/// (`RuntimeObjectInterface.GenerationOptions.marksAttachedMacros`). MachOSwiftSection marks each
/// attribute it prints with an annotation region of the macro's kind, and prints the expansion
/// itself (`SwiftDeclarationPrinter.printMacroExpansion(of:attachedTo:level:)`), under the same
/// configuration as the interface; RuntimeViewer does not assemble it.
public struct RuntimeInterfaceMacroExpansion: Codable, Sendable {
    /// The macro as its attribute names it, `Observation.Observable`.
    public let macroName: String

    /// Where the attribute is in the interface's text, in UTF-8 offsets, as the comment structure
    /// counts them.
    public let attributeUTF8Range: Range<Int>

    /// The declarations the macro generated, indented one level as members of the type the
    /// attribute is on, with the generated extension at the attribute's own level.
    public let expansionString: FrozenSemanticString

    public init(macroName: String, attributeUTF8Range: Range<Int>, expansionString: FrozenSemanticString) {
        self.macroName = macroName
        self.attributeUTF8Range = attributeUTF8Range
        self.expansionString = expansionString
    }
}
