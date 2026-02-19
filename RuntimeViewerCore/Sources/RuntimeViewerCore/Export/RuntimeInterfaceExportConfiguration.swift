public import Foundation

public struct RuntimeInterfaceExportConfiguration: Sendable {
    public enum Format: Int, Sendable {
        case singleFile = 0
        case directory = 1
    }

    public let imagePath: String
    public let imageName: String
    public let directory: URL
    public let objcFormat: Format
    public let swiftFormat: Format
    public let generationOptions: RuntimeObjectInterface.GenerationOptions

    public init(
        imagePath: String,
        imageName: String,
        directory: URL,
        objcFormat: Format,
        swiftFormat: Format,
        generationOptions: RuntimeObjectInterface.GenerationOptions
    ) {
        self.imagePath = imagePath
        self.imageName = imageName
        self.directory = directory
        self.objcFormat = objcFormat
        self.swiftFormat = swiftFormat
        self.generationOptions = generationOptions
    }
}
