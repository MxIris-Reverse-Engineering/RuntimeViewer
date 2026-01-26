import Foundation
import MetaCodable

extension RuntimeObjectInterface {
    @Codable
    public struct GenerationOptions {
        @Default(ifMissing: ObjCGenerationOptions())
        public var objcHeaderOptions: ObjCGenerationOptions
        @Default(ifMissing: SwiftGenerationOptions())
        public var swiftInterfaceOptions: SwiftGenerationOptions

        public init() {
            self.objcHeaderOptions = .init()
            self.swiftInterfaceOptions = .init()
        }

        public init(objcHeaderOptions: ObjCGenerationOptions, swiftInterfaceOptions: SwiftGenerationOptions) {
            self.objcHeaderOptions = objcHeaderOptions
            self.swiftInterfaceOptions = swiftInterfaceOptions
        }
    }
}
