import Foundation
import MetaCodable

extension RuntimeObjectInterface {
    @Codable
    public struct GenerationOptions: Sendable {
        @Default(ifMissing: ObjCGenerationOptions())
        public var objcHeaderOptions: ObjCGenerationOptions

        @Default(ifMissing: SwiftGenerationOptions())
        public var swiftInterfaceOptions: SwiftGenerationOptions

        @Default(ifMissing: TransformerConfiguration())
        public var transformerConfiguration: TransformerConfiguration

        public init() {
            self.objcHeaderOptions = .init()
            self.swiftInterfaceOptions = .init()
            self.transformerConfiguration = .init()
        }

        public init(
            objcHeaderOptions: ObjCGenerationOptions,
            swiftInterfaceOptions: SwiftGenerationOptions,
            transformerConfiguration: TransformerConfiguration = .init()
        ) {
            self.objcHeaderOptions = objcHeaderOptions
            self.swiftInterfaceOptions = swiftInterfaceOptions
            self.transformerConfiguration = transformerConfiguration
        }
    }
}
