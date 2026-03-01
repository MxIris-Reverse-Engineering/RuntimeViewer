import Foundation
import MetaCodable

extension RuntimeObjectInterface {
    @Codable
    public struct GenerationOptions: Sendable {
        @Default(ifMissing: ObjCGenerationOptions())
        public var objcHeaderOptions: ObjCGenerationOptions

        @Default(ifMissing: SwiftGenerationOptions())
        public var swiftInterfaceOptions: SwiftGenerationOptions

        @Default(ifMissing: Transformer.Configuration())
        public var transformer: Transformer.Configuration

        public init() {
            self.objcHeaderOptions = .init()
            self.swiftInterfaceOptions = .init()
            self.transformer = .init()
        }

        public init(
            objcHeaderOptions: ObjCGenerationOptions,
            swiftInterfaceOptions: SwiftGenerationOptions,
            transformer: Transformer.Configuration = .init()
        ) {
            self.objcHeaderOptions = objcHeaderOptions
            self.swiftInterfaceOptions = swiftInterfaceOptions
            self.transformer = transformer
        }

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
                emitOffsetComments: true,
                printMemberAddress: true,
                printTypeLayout: true,
                printEnumLayout: true,
                synthesizeOpaqueType: true
            )
        )
    }
}
