import Foundation

extension String {
    /// Extract content inside the first pair of parentheses
    var contentInParentheses: String? {
        guard let range = self.range(of: "(?<=\\().*?(?=\\))", options: .regularExpression) else {
            return nil
        }
        return String(self[range])
    }
    
    /// Extract all contents inside parentheses
    var allContentsInParentheses: [String] {
        let pattern = "\\(([^)]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: self, range: NSRange(startIndex..., in: self))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: self) else { return nil }
            return String(self[range])
        }
    }
}
