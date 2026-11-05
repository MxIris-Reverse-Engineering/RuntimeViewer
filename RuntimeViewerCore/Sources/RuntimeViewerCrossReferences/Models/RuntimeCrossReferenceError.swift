public import Foundation
import RuntimeViewerCore

public enum RuntimeCrossReferenceError: Error, LocalizedError, Sendable, Equatable {
    /// The process serving the engine does not run arm64 code.
    case unsupportedArchitecture
    case imageNotFound(path: String)
    /// The scope names an image the engine has not indexed, whose code a
    /// query does not read.
    case imageNotIndexed(path: String)
    case functionNotFound(imagePath: String, address: UInt64)
    case memberNotFound(objectName: String, memberName: String)
    /// A selector is a message, not code: it has senders but no callees.
    case selectorHasNoCallees(String)
    /// Type references are found for Objective-C classes and for Swift
    /// structs, enums and classes; the object is none of these, or its image
    /// does not define it.
    case typeNotFound(objectName: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            "Cross references read arm64 and arm64e machine code; the process serving this engine runs neither."
        case .imageNotFound(let path):
            "No image at \(path) is loaded or in the shared cache of the process serving this engine."
        case .imageNotIndexed(let path):
            "\((path as NSString).lastPathComponent) is not indexed. Cross references read indexed images only: load it first."
        case .functionNotFound(let imagePath, let address):
            "No function holds 0x\(String(address, radix: 16)) in \(imagePath)."
        case .memberNotFound(let objectName, let memberName):
            "\(objectName) has no member \(memberName) with code — or its image is not loaded in the engine."
        case .selectorHasNoCallees(let selector):
            "\(selector) is a selector: it has senders, but no code of its own to call anything."
        case .typeNotFound(let objectName):
            "\(objectName) is not an Objective-C class or a Swift struct, enum or class its image defines, so its references cannot be found."
        }
    }
}
