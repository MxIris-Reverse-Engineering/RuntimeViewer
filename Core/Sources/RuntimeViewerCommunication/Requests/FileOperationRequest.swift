public import Foundation

public enum FileOperation: Codable {
    case createDirectory(url: URL, isIntermediateDirectories: Bool)
    case remove(url: URL)
    case move(from: URL, to: URL)
    case copy(from: URL, to: URL)
    case write(url: URL, data: Data)
}

public struct FileOperationRequest: Codable, RuntimeRequest {
    public typealias Response = VoidResponse

    public static let identifier = "com.JH.RuntimeViewerService.FileOperationRequest"

    public let operation: FileOperation

    public init(operation: FileOperation) {
        self.operation = operation
    }
}
