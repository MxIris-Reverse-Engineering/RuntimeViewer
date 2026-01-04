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

extension String {
    @inlinable
    var uppercasedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }

    @inlinable
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }

    @inlinable
    var uppercasedLast: String {
        dropLast() + suffix(1).uppercased()
    }

    @inlinable
    var lowercasedLast: String {
        dropLast() + suffix(1).lowercased()
    }

    func uppercased(at index: Int) -> String {
        return transform(at: index) { $0.uppercased() }
    }

    func lowercased(at index: Int) -> String {
        return transform(at: index) { $0.lowercased() }
    }

    func uppercased(in range: Range<Int>) -> String {
        return transform(in: range) { $0.uppercased() }
    }

    func uppercased(in range: ClosedRange<Int>) -> String {
        return transform(in: Range(range)) { $0.uppercased() }
    }

    func lowercased(in range: Range<Int>) -> String {
        return transform(in: range) { $0.lowercased() }
    }

    func lowercased(in range: ClosedRange<Int>) -> String {
        return transform(in: Range(range)) { $0.lowercased() }
    }

    private func transform(at index: Int, _ transformer: (String) -> String) -> String {
        guard index >= 0 && index < count else { return self }

        let startIdx = self.index(startIndex, offsetBy: index)
        let charRange = startIdx ..< self.index(after: startIdx)
        return replacingCharacters(in: charRange, with: transformer(String(self[startIdx])))
    }

    private func transform(in range: Range<Int>, _ transformer: (String) -> String) -> String {
        let clampedLower = max(0, range.lowerBound)
        let clampedUpper = min(count, range.upperBound)
        guard clampedLower < clampedUpper else { return self }

        let startIdx = index(startIndex, offsetBy: clampedLower)
        let endIdx = index(startIndex, offsetBy: clampedUpper)
        let swiftRange = startIdx ..< endIdx

        let subStr = String(self[swiftRange])
        return replacingCharacters(in: swiftRange, with: transformer(subStr))
    }
}

extension Set {
    @inlinable mutating func insert<S>(contentsOf newElements: S) where S: Sequence, Element == S.Element {
        for newElement in newElements {
            insert(newElement)
        }
    }
}
