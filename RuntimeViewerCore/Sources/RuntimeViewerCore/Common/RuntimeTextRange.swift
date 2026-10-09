public import Foundation

/// A UTF-16 range inside a piece of text — what `NSRange` expresses — in a
/// form that crosses the engine boundary.
///
/// UTF-16 rather than UTF-8 or `Character` offsets because every consumer on
/// the app side (`NSAttributedString`, `NSTextView`, the SourceEditor bridge)
/// indexes text that way, and converting once here beats converting in each
/// of them.
public struct RuntimeTextRange: Hashable, Codable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}
