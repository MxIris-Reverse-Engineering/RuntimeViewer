public import Foundation

extension RuntimeObject {
    public var exportFileName: String {
        let sanitized = displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        switch kind {
        case .swift:
            return "\(sanitized).swiftinterface"
        case .objc, .c:
            return "\(sanitized).h"
        }
    }
}
