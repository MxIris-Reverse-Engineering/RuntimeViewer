import Foundation

extension Optional where Wrapped: Collection {
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
    mutating func removeFirst(_ element: Element) -> Element? {
        if let index = firstIndex(of: element) {
            return remove(at: index)
        }
        return nil
    }

    mutating func removeAll(_ element: Element) {
        removeAll(where: { $0 == element })
    }

    func removingFirst(_ element: Element) -> [Element] {
        var newArray = self
        newArray.removeFirst(element)
        return newArray
    }

    func removingAll(_ element: Element) -> [Element] {
        return filter { $0 != element }
    }

    mutating func remove(contentsOf elements: [Element]) {
        removeAll { elements.contains($0) }
    }

    func removing(contentsOf elements: [Element]) -> [Element] {
        return filter { !elements.contains($0) }
    }
}

extension Array {
    func removingAll(where shouldBeRemoved: (Element) throws -> Bool) rethrows -> [Element] {
        var copy = self
        try copy.removeAll(where: shouldBeRemoved)
        return copy
    }
}

extension String {
    
    // MARK: - 1. 首字符 & 尾字符处理
    
    /// 返回首字母大写的新字符串
    var uppercasedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
    
    /// 返回首字母小写的新字符串
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
    
    /// 返回尾字母大写的新字符串
    var uppercasedLast: String {
        dropLast() + suffix(1).uppercased()
    }
    
    /// 返回尾字母小写的新字符串
    var lowercasedLast: String {
        dropLast() + suffix(1).lowercased()
    }
    
    // MARK: - 2. 指定 Index (Int) 处理
    
    /// 将指定索引位置的字符变为大写
    /// - Parameter index: 整数索引 (0 based)
    func uppercased(at index: Int) -> String {
        return transform(at: index) { $0.uppercased() }
    }
    
    /// 将指定索引位置的字符变为小写
    /// - Parameter index: 整数索引 (0 based)
    func lowercased(at index: Int) -> String {
        return transform(at: index) { $0.lowercased() }
    }
    
    // MARK: - 3. 指定 Range 处理
    
    /// 将指定范围内的字符变为大写
    /// - Parameter range: 整数范围 (例如 1...3)
    func uppercased(in range: Range<Int>) -> String {
        return transform(in: range) { $0.uppercased() }
    }
    
    func uppercased(in range: ClosedRange<Int>) -> String {
        return transform(in: Range(range)) { $0.uppercased() }
    }
    
    /// 将指定范围内的字符变为小写
    /// - Parameter range: 整数范围 (例如 1..<4)
    func lowercased(in range: Range<Int>) -> String {
        return transform(in: range) { $0.lowercased() }
    }
    
    func lowercased(in range: ClosedRange<Int>) -> String {
        return transform(in: Range(range)) { $0.lowercased() }
    }
    
    // MARK: - Private Helpers (核心逻辑)
    
    /// 辅助方法：处理单个索引变换
    private func transform(at index: Int, _ transformer: (String) -> String) -> String {
        guard index >= 0 && index < count else { return self }
        
        let startIdx = self.index(startIndex, offsetBy: index)
        let charRange = startIdx..<self.index(after: startIdx)
        return self.replacingCharacters(in: charRange, with: transformer(String(self[startIdx])))
    }
    
    /// 辅助方法：处理范围变换
    private func transform(in range: Range<Int>, _ transformer: (String) -> String) -> String {
        // 边界检查：确保范围在字符串有效长度内
        let clampedLower = max(0, range.lowerBound)
        let clampedUpper = min(count, range.upperBound)
        guard clampedLower < clampedUpper else { return self }
        
        let startIdx = self.index(startIndex, offsetBy: clampedLower)
        let endIdx = self.index(startIndex, offsetBy: clampedUpper)
        let swiftRange = startIdx..<endIdx
        
        let subStr = String(self[swiftRange])
        return self.replacingCharacters(in: swiftRange, with: transformer(subStr))
    }
}
