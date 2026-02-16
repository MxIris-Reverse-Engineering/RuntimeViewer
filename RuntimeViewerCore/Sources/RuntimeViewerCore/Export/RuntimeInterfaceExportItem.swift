import Foundation

public struct RuntimeInterfaceExportItem: Sendable {
    public let object: RuntimeObject
    public let plainText: String
    public let suggestedFileName: String

    public init(object: RuntimeObject, plainText: String, suggestedFileName: String) {
        self.object = object
        self.plainText = plainText
        self.suggestedFileName = suggestedFileName
    }

    public var fileExtension: String {
        switch object.kind {
        case .swift: return "swiftinterface"
        case .objc, .c: return "h"
        }
    }

    public var isSwift: Bool {
        if case .swift = object.kind { return true }
        return false
    }
}
