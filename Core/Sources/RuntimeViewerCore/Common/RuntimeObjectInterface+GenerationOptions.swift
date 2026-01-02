import Foundation

extension RuntimeObjectInterface {
    public struct GenerationOptions: Codable {
        public var objcHeaderOptions: ObjCGenerationOptions
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
