import Foundation
import MetaCodable

extension RuntimeObjectInterface {
    @Codable
    @MemberInit
    public struct GenerationOptions: Sendable, Equatable, Hashable {
        @Default(ObjCGenerationOptions.default)
        public var objcHeaderOptions: ObjCGenerationOptions

        @Default(SwiftGenerationOptions.default)
        public var swiftInterfaceOptions: SwiftGenerationOptions

        @Default(Transformer.Configuration.default)
        public var transformer: Transformer.Configuration

        /// Asks the printers to say what each comment is and how it divides, and the engine to
        /// send that as `RuntimeObjectInterface.commentStructure` — for a viewer that draws the
        /// comments itself. The text is the same either way.
        ///
        /// Not a Generation Option the user sets: the content pane decides it for each request
        /// (the SourceEditor pane with Comment Tags on), so a stored value is always the default.
        /// A peer that predates it ignores the key and sends no structure.
        @Default(false)
        public var marksCommentStructure: Bool

        /// Options tuned for MCP usage: all strip options disabled, all add options enabled,
        /// all Swift detail options enabled, and every Swift declaration printed, exported
        /// or not. Provides maximum information to LLM clients.
        public static let mcp = GenerationOptions(
            objcHeaderOptions: ObjCGenerationOptions(
                stripProtocolConformance: false,
                stripOverrides: false,
                stripSynthesizedIvars: false,
                stripSynthesizedMethods: false,
                stripCtorMethod: false,
                stripDtorMethod: false,
                addIvarOffsetComments: true,
                addPropertyAttributesComments: true,
                addMethodIMPAddressComments: true,
                addPropertyAccessorAddressComments: true
            ),
            swiftInterfaceOptions: SwiftGenerationOptions(
                printStrippedSymbolicItem: true,
                printFieldOffset: true,
                printExpandedFieldOffset: true,
                printVTableOffset: true,
                printPWTOffset: true,
                printMemberAddress: true,
                printTypeLayout: true,
                printEnumLayout: true,
                synthesizeOpaqueType: true,
                printExportedDeclarationsOnly: false
            )
        )
    }
}
