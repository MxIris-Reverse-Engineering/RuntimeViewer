/// Where each line of a UTF-8 text begins, and the two lookups the matcher
/// and the corpus entries both need: the line a byte is on, and a line's
/// range without its terminator. Offsets are UTF-8 bytes, as everywhere in
/// the search.
struct RuntimeInterfaceLineTable: Sendable {
    /// UTF-8 offsets at which lines begin; the first is always 0.
    let lineStartOffsets: [Int]

    /// The text's length in UTF-8 bytes, where its last line ends.
    let utf8Count: Int

    init(_ text: String) {
        var lineStartOffsets = [0]
        var text = text
        utf8Count = text.withUTF8 { bytes in
            for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
                lineStartOffsets.append(index + 1)
            }
            return bytes.count
        }
        self.lineStartOffsets = lineStartOffsets
    }

    var lineCount: Int {
        lineStartOffsets.count
    }

    /// 0-based index of the line containing the byte at `offset`: the last
    /// line start at or before it.
    func lineIndex(containingUTF8Offset offset: Int) -> Int {
        var lowerBound = 0
        var upperBound = lineStartOffsets.count - 1
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound + 1) / 2
            if lineStartOffsets[middle] <= offset {
                lowerBound = middle
            } else {
                upperBound = middle - 1
            }
        }
        return lowerBound
    }

    /// UTF-8 range of line `lineIndex`, without its terminator.
    func lineUTF8Range(at lineIndex: Int) -> Range<Int> {
        let start = lineStartOffsets[lineIndex]
        let end = lineIndex + 1 < lineStartOffsets.count ? lineStartOffsets[lineIndex + 1] - 1 : utf8Count
        return start ..< max(start, end)
    }
}
