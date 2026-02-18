import Foundation

struct RuntimeInterfaceExportItem: Sendable {
    let object: RuntimeObject
    let plainText: String
    let suggestedFileName: String

    var fileExtension: String {
        switch object.kind {
        case .swift: return "swiftinterface"
        case .objc, .c: return "h"
        }
    }

    var isSwift: Bool {
        if case .swift = object.kind { return true }
        return false
    }
}
