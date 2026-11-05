import Foundation

extension Array where Element: Equatable {
    @discardableResult
    @inlinable
    mutating func removeFirst(_ element: Element) -> Element? {
        if let index = firstIndex(of: element) {
            return remove(at: index)
        }
        return nil
    }

    @inlinable
    mutating func removeAll(_ element: Element) {
        removeAll(where: { $0 == element })
    }

    @inlinable
    func removingFirst(_ element: Element) -> [Element] {
        var newArray = self
        newArray.removeFirst(element)
        return newArray
    }

    @inlinable
    func removingAll(_ element: Element) -> [Element] {
        return filter { $0 != element }
    }

    @inlinable
    mutating func remove(contentsOf elements: [Element]) {
        removeAll { elements.contains($0) }
    }

    @inlinable
    func removing(contentsOf elements: [Element]) -> [Element] {
        return filter { !elements.contains($0) }
    }
}

extension Array {
    @inlinable
    func removingAll(where shouldBeRemoved: (Element) throws -> Bool) rethrows -> [Element] {
        var copy = self
        try copy.removeAll(where: shouldBeRemoved)
        return copy
    }
}
