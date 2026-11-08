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

// `Definition` is class-bound, so the generated `box` setter must not assign `self`: from
// FrameworkToolbox 0.14 on it does unless told otherwise, and the compiler crashes in SILGen
// instead of reporting it.
@FrameworkToolboxExtension(.internal)
extension SwiftDeclaration.Definition {}
