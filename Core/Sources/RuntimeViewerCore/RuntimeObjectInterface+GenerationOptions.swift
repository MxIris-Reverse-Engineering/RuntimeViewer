import Foundation
import ClassDumpRuntimeSwift
import SwiftDump

extension RuntimeObjectInterface {
    public struct GenerationOptions: Codable {
        public var objcHeaderOptions: CDGenerationOptions
        public var swiftInterfaceOptions: SwiftGenerationOptions
        
        public init() {
            objcHeaderOptions = .init()
            swiftInterfaceOptions = .init()
        }
        public init(objcHeaderOptions: CDGenerationOptions, swiftInterfaceOptions: SwiftGenerationOptions) {
            self.objcHeaderOptions = objcHeaderOptions
            self.swiftInterfaceOptions = swiftInterfaceOptions
        }
    }
}
