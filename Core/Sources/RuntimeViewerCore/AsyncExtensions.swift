import Foundation

extension Optional {
    @inlinable package func asyncMap<E, U>(_ transform: (Wrapped) async throws(E) -> U) async throws(E) -> U? where E: Swift.Error, U: ~Copyable {
        switch self {
        case .none:
            return nil
        case .some(let wrapped):
            return try await transform(wrapped)
        }
    }
}

extension Sequence {
    @inlinable package func asyncMap<T, E>(_ transform: (Element) async throws(E) -> T) async throws(E) -> [T] where E: Swift.Error {
        var results: [T] = []
        for element in self {
            try await results.append(transform(element))
        }
        return results
    }
}
