import Semantic
import ObjCDeclarationRendering
@_spi(Support) import SwiftPrinting

/// The Generation Options a search reads the corpus under, as the predicate
/// a `VisibilityRegionTable` projection takes.
///
/// The corpus is printed once with everything any option could show, each
/// optional piece marked with the option it depends on (proposal
/// `0029-find-navigator` §1). The option names are the printers' own —
/// `objc.…` from MachOObjCSection, `swift.…` from MachOSwiftSection — so the
/// answer comes from their predicates, fed with what RuntimeViewer's options
/// map to.
struct RuntimeInterfaceVisibility: Sendable {
    private let objcOptions: ObjCGenerationOptions

    private let swiftConfiguration: SwiftDeclarationPrintConfiguration

    private let resolvesOpaqueTypes: Bool

    init(_ options: RuntimeObjectInterface.GenerationOptions) {
        objcOptions = options.objcHeaderOptions
        // The mapping the content pane's printer is configured with
        // (`RuntimeSwiftSection.buildPrintConfiguration`).
        var swiftConfiguration = SwiftDeclarationPrintConfiguration()
        swiftConfiguration.applySwitches(of: options.swiftInterfaceOptions)
        self.swiftConfiguration = swiftConfiguration
        resolvesOpaqueTypes = options.swiftInterfaceOptions.resolvesOpaqueTypes
    }

    /// Whether the option a region is conditioned on is on. The two
    /// printers' names never overlap, and a name neither knows reads as off.
    func isOptionEnabled(_ optionName: String) -> Bool {
        objcOptions.isVisibilityOptionEnabled(optionName)
            || swiftConfiguration.isVisibilityOptionEnabled(optionName, resolvesOpaqueTypes: resolvesOpaqueTypes)
    }
}

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
