import Foundation

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
