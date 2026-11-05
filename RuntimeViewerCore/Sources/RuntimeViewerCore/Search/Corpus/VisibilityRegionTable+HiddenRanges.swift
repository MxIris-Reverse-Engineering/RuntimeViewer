import Semantic
import ObjCDeclarationRendering
@_spi(Support) import SwiftPrinting

extension VisibilityRegionTable {
    /// The UTF-8 ranges of a text of `utf8Count` bytes that a projection
    /// under `isOptionEnabled` takes out — the bytes
    /// `projection(of:where:)` drops: every region whose condition does not
    /// hold, in text order, merged where two touch or overlap, so each range
    /// is one seam of the projected text. An empty region drops nothing and
    /// is left out.
    func hiddenUTF8Ranges(inTextOfUTF8Count utf8Count: Int, where isOptionEnabled: (String) -> Bool) -> [Range<Int>] {
        let conditionHolds = conditions.map { $0.isSatisfied(where: isOptionEnabled) }
        let hiddenRanges = regions.compactMap { region -> Range<Int>? in
            guard !conditionHolds[Int(region.conditionIndex)] else { return nil }
            let lowerBound = min(Int(region.utf8Offset), utf8Count)
            let upperBound = min(Int(region.utf8Offset) + Int(region.utf8Length), utf8Count)
            return lowerBound < upperBound ? lowerBound ..< upperBound : nil
        }
        .sorted { $0.lowerBound < $1.lowerBound }
        var mergedRanges: [Range<Int>] = []
        for range in hiddenRanges {
            if let lastRange = mergedRanges.last, range.lowerBound <= lastRange.upperBound {
                mergedRanges[mergedRanges.count - 1] = lastRange.lowerBound ..< max(lastRange.upperBound, range.upperBound)
            } else {
                mergedRanges.append(range)
            }
        }
        return mergedRanges
    }
}
