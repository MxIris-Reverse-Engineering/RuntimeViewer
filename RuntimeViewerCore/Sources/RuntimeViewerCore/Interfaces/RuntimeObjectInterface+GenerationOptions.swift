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

        /// Asks the engine to send, with an interface printed folded, the attached macros it shows
        /// — `@Observation.Observable` on a class compiled from `@Observable` — each with where its
        /// attribute is and the declarations it generated (`RuntimeObjectInterface.macroExpansions`),
        /// for a viewer that shows them below the attribute as Xcode shows an expanded macro. The
        /// text is the same either way.
        ///
        /// Not a Generation Option the user sets: the content pane decides it for each request (the
        /// SourceEditor pane), like `marksCommentStructure`. A peer that predates it ignores the key
        /// and sends no expansions.
        @Default(false)
        public var marksAttachedMacros: Bool

        /// Mark in an Objective-C header the `NS_SWIFT_NAME(...)` and `NS_REFINED_FOR_SWIFT` the SDK's
        /// API notes give the class, protocol or category and its members, read from the SDK of the Mac
        /// serving the engine (swift-type-indexing). A top-level option rather than one of
        /// `objcHeaderOptions`, which are MachOObjCSection's: it only decides whether the engine hands
        /// the builder these notes. On in settings saved before it existed.
        @Default(true)
        public var marksSwiftNamesFromAPINotes: Bool

        /// Wait, before printing, until the serving Mac's type index has what the image needs, so the
        /// text never carries `__C.` names the index would resolve a moment later. For the callers that
        /// print once and keep the text — MCP, the command-line tool, interface export, the Find
        /// corpus; the content pane leaves it off and shows the resolved names when they arrive
        /// (`RuntimeDataChange.typeNamesResolved`). Waiting happens only the first time an SDK
        /// module's interface is generated. A peer that predates it ignores the key.
        @Default(false)
        public var waitsForTypeIndex: Bool

        /// The language to write the interface in: `nil` for the object's own; `.swift` asks for an
        /// Objective-C class, category or protocol as Swift imports it (Generated Interface).
        ///
        /// Not a Generation Option the user sets: the content pane decides it for each request, from
        /// the navigation entry it shows. A peer that predates it ignores the key and answers in the
        /// object's own language, which `RuntimeObjectInterface.interfaceLanguage` then tells.
        public var interfaceLanguage: RuntimeInterfaceLanguage? = nil

        /// Options tuned for MCP usage: all strip options disabled, all add options enabled,
        /// all Swift detail options enabled, every declaration printed, exported or not, and
        /// macro expansions printed as the binary holds them. Provides maximum information to
        /// LLM clients.
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
                addPropertyAccessorAddressComments: true,
                printExportedDeclarationsOnly: false
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
                printExportedDeclarationsOnly: false,
                expandsMacros: true,
                // An LLM client searches the text a declaration at a time; one broken over
                // several lines no longer matches a search for it whole.
                breaksLongTypes: false
            ),
            // An LLM client reads the text once: it waits for the resolved names rather than
            // getting `__C.` ones the index resolves a moment later.
            waitsForTypeIndex: true
        )
    }
}
