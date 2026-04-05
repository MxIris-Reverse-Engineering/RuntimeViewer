import Foundation
import MetaCodable

extension RuntimeObjectInterface {
    @Codable
    @MemberInit
    public struct GenerationOptions: Sendable {
        @Default(ObjCGenerationOptions.default)
        public var objcHeaderOptions: ObjCGenerationOptions

        @Default(SwiftGenerationOptions.default)
        public var swiftInterfaceOptions: SwiftGenerationOptions

        @Default(Transformer.Configuration.default)
        public var transformer: Transformer.Configuration

        /// Options tuned for MCP usage: all strip options disabled, all add options enabled,
        /// all Swift detail options enabled. Provides maximum information to LLM clients.
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
                synthesizeOpaqueType: true
            )
        )
    }
}
