import Foundation

public struct RuntimeInterfaceExportConfiguration: Sendable {
    public let scope: Scope
    public let format: Format
    public let generationOptions: RuntimeObjectInterface.GenerationOptions

    public init(scope: Scope, format: Format, generationOptions: RuntimeObjectInterface.GenerationOptions) {
        self.scope = scope
        self.format = format
        self.generationOptions = generationOptions
    }

    public enum Scope: Sendable {
        case singleObject(RuntimeObject)
        case image(String)
    }

    public enum Format: Sendable {
        case singleFile
        case directory
    }
}
