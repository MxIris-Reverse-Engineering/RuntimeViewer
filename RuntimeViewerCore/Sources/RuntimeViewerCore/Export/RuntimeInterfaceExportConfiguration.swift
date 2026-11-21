public import Foundation

public struct RuntimeInterfaceExportConfiguration: Sendable {
    public enum Format: Int, Sendable, Codable {
        case singleFile = 0
        case directory = 1
    }

    public let imagePath: String
    public let imageName: String
    public let directory: URL
    public let objcFormat: Format
    public let swiftFormat: Format
    public let cPlusPlusFormat: Format
    public let generationOptions: RuntimeObjectInterface.GenerationOptions
    public let includeMetadata: Bool
    /// Whether the export asks for the image's C++ objects
    /// (`objects(in:includesCPlusPlusObjects:)`) and writes them. Off by
    /// default, so a caller that predates C++ objects exports what it did
    /// (proposal `cplusplus-export`).
    public let includesCPlusPlusObjects: Bool

    public init(
        imagePath: String,
        imageName: String,
        directory: URL,
        objcFormat: Format,
        swiftFormat: Format,
        cPlusPlusFormat: Format = .directory,
        generationOptions: RuntimeObjectInterface.GenerationOptions,
        includeMetadata: Bool = true,
        includesCPlusPlusObjects: Bool = false
    ) {
        self.imagePath = imagePath
        self.imageName = imageName
        self.directory = directory
        self.objcFormat = objcFormat
        self.swiftFormat = swiftFormat
        self.cPlusPlusFormat = cPlusPlusFormat
        self.generationOptions = generationOptions
        self.includeMetadata = includeMetadata
        self.includesCPlusPlusObjects = includesCPlusPlusObjects
    }

    /// The format the user chose for the interfaces of `group`.
    func format(for group: RuntimeInterfaceExportItem.Group) -> Format {
        switch group {
        case .objectiveC: objcFormat
        case .swift: swiftFormat
        case .cPlusPlus: cPlusPlusFormat
        }
    }
}
