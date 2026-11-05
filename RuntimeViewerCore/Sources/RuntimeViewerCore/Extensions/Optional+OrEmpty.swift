import Foundation

extension Optional where Wrapped: Collection {
    @inlinable
    var orEmpty: [Wrapped.Element] {
        switch self {
        case .none:
            return []
        case .some(let wrapped):
            return .init(wrapped)
        }
    }
}
