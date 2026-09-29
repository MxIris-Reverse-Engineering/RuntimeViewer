import Semantic
import ObjCDeclarationRendering
@_spi(Support) import SwiftPrinting

/// The Generation Options a search reads the corpus under, as the predicate
/// a `VisibilityRegionTable` projection takes.
///
/// The corpus is printed once with everything any option could show, each
/// optional piece marked with the option it depends on (proposal
/// `draft-find-navigator` §1). The option names are the printers' own —
/// `objc.…` from MachOObjCSection, `swift.…` from MachOSwiftSection — so the
/// answer comes from their predicates, fed with what RuntimeViewer's options
/// map to.
struct RuntimeInterfaceVisibility: Sendable {
    private let objcOptions: ObjCGenerationOptions

    private let swiftConfiguration: SwiftDeclarationPrintConfiguration

    private let resolvesOpaqueTypes: Bool

    init(_ options: RuntimeObjectInterface.GenerationOptions) {
        objcOptions = options.objcHeaderOptions
        let swiftOptions = options.swiftInterfaceOptions
        var swiftConfiguration = SwiftDeclarationPrintConfiguration()
        swiftConfiguration.printStrippedSymbolicItem = swiftOptions.printStrippedSymbolicItem
        swiftConfiguration.printFieldOffset = swiftOptions.printFieldOffset
        swiftConfiguration.printExpandedFieldOffsets = swiftOptions.printExpandedFieldOffset
        swiftConfiguration.printMemberAddress = swiftOptions.printMemberAddress
        swiftConfiguration.printVTableOffset = swiftOptions.printVTableOffset
        swiftConfiguration.printPWTOffset = swiftOptions.printPWTOffset
        swiftConfiguration.printTypeLayout = swiftOptions.printTypeLayout
        swiftConfiguration.printEnumLayout = swiftOptions.printEnumLayout
        swiftConfiguration.infersObjCOverridesFromSelectorNames = swiftOptions.infersObjCOverridesFromSelectorNames
        self.swiftConfiguration = swiftConfiguration
        // The display path registers the opaque type resolver exactly when
        // this is on (`RuntimeSwiftSection.updateConfiguration`).
        resolvesOpaqueTypes = swiftOptions.synthesizeOpaqueType
    }

    /// Whether the option a region is conditioned on is on. The two
    /// printers' names never overlap, and a name neither knows reads as off.
    func isOptionEnabled(_ optionName: String) -> Bool {
        objcOptions.isVisibilityOptionEnabled(optionName)
            || swiftConfiguration.isVisibilityOptionEnabled(optionName, resolvesOpaqueTypes: resolvesOpaqueTypes)
    }
}
