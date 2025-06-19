import Foundation
import ClassDumpRuntimeSwift
import SwiftDump

extension RuntimeObjectInterface {
    public struct GenerationOptions: Codable {
        public let objcHeaderOptions: CDGenerationOptions
        public let swiftDemangleOptions: DemangleOptions
        public init(objcHeaderOptions: CDGenerationOptions, swiftDemangleOptions: DemangleOptions) {
            self.objcHeaderOptions = objcHeaderOptions
            self.swiftDemangleOptions = swiftDemangleOptions
        }
    }
}
