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
    }
}
