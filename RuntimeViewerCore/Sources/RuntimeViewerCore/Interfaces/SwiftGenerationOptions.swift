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

@Codable
@MemberInit
public struct SwiftGenerationOptions: Sendable, Equatable, Hashable {
    public enum MemberSortOrder: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case byCategory
        case byOffset
    }

    @Default(true)
    public var printStrippedSymbolicItem: Bool

    @Default(false)
    public var printFieldOffset: Bool

    @Default(false)
    public var printExpandedFieldOffset: Bool

    @Default(false)
    public var printVTableOffset: Bool

    @Default(false)
    public var printPWTOffset: Bool

    @Default(false)
    public var printMemberAddress: Bool

    @Default(false)
    public var printTypeLayout: Bool

    @Default(false)
    public var printEnumLayout: Bool

    @Default(false)
    public var synthesizeOpaqueType: Bool

    @Default(MemberSortOrder.byCategory)
    public var memberSortOrder: MemberSortOrder

    @Default(false)
    public var infersObjCOverridesFromSelectorNames: Bool

    /// Leave out what the image does not export: the types, protocols and
    /// extensions MachOSwiftSection rules not exported, with everything in
    /// them, and the members of the others that are not exported.
    /// Declarations it cannot judge are kept. An object left with nothing
    /// prints as empty. Off in settings saved before it existed.
    @Default(false)
    public var printExportedDeclarationsOnly: Bool

    /// Show what an attached macro generated as the binary holds it instead of as its source reads.
    /// Off, a class compiled from `@Observable` prints with `@Observation.Observable` and each tracked
    /// property as a plain `var`; on, it prints the registrar, the `_x` storage, the computed
    /// properties and the generated methods — MachOSwiftSection's `expandsMacros`. Off in settings
    /// saved before it existed.
    @Default(false)
    public var expandsMacros: Bool

    public static let `default` = Self()
}

extension SwiftGenerationOptions {
    /// Whether the printer resolves opaque types: the content pane registers
    /// the opaque type resolver exactly when this is on, and a search's
    /// visibility predicate reads the corpus's resolved constraints under it.
    var resolvesOpaqueTypes: Bool {
        synthesizeOpaqueType
    }
}
