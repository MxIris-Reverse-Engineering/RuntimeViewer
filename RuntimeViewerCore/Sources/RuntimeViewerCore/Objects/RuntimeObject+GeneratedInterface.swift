import Foundation

extension RuntimeObject {
    /// Whether the object can be shown as Swift imports it (Generated Interface): an Objective-C
    /// class, category or protocol. A C struct or union has no such view, and a Swift object is
    /// Swift already.
    public var hasGeneratedInterface: Bool {
        if case .objc = kind {
            return true
        }
        return false
    }
}
