import Foundation

extension RuntimeObject {
    public var exportFileName: String {
        let sanitized = displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        switch kind {
        case .swift:
            return "\(sanitized).swiftinterface"
        case .objc(.type(.class)), .c:
            return "\(sanitized).h"
        case .objc(.type(.protocol)):
            return "\(sanitized)-Protocol.h"
        case .objc(.category(_)):
            if let categoryName = sanitized.contentInParentheses {
                return "\(sanitized)+\(categoryName).h"
            } else {
                return "\(sanitized).h"
            }
        }
    }
}
