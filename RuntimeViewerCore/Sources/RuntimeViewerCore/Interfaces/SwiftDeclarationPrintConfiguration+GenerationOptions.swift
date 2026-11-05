@_spi(Support) import SwiftDeclaration
@_spi(Support) import SwiftDeclarationRendering
@_spi(Support) import SwiftIndexing
@_spi(Support) import SwiftSpecialization
@_spi(Support) import SwiftPrinting
@_spi(Support) import SwiftInterface
@_spi(Support) import SwiftPrivateDiscriminators
@_spi(Internals) import SwiftInspection
import Demangling
import Foundation
import FoundationToolbox
import FrameworkToolbox
import MachOKit
import MachODependencies
import MachOObjCSection
import MachOSwiftSection
import OrderedCollections
import Semantic
import MetaCodable

extension SwiftDeclarationPrintConfiguration {
    /// Sets the switches RuntimeViewer's Swift Generation Options decide —
    /// the one mapping from those options to the printer's. The content
    /// pane's printer is configured with it, and a Find search reads the
    /// corpus under it (`RuntimeInterfaceVisibility`), so the two cannot
    /// disagree on what an option shows.
    mutating func applySwitches(of options: SwiftGenerationOptions) {
        printStrippedSymbolicItem = options.printStrippedSymbolicItem
        printFieldOffset = options.printFieldOffset
        printExpandedFieldOffsets = options.printExpandedFieldOffset
        printMemberAddress = options.printMemberAddress
        printVTableOffset = options.printVTableOffset
        printPWTOffset = options.printPWTOffset
        printTypeLayout = options.printTypeLayout
        printEnumLayout = options.printEnumLayout
        infersObjCOverridesFromSelectorNames = options.infersObjCOverridesFromSelectorNames
        printExportedDeclarationsOnly = options.printExportedDeclarationsOnly
    }
}
