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

extension SwiftDeclaration.TypeName {
    var runtimeObjectKind: RuntimeObjectKind {
        switch kind {
        case .enum:
            return .swift(.type(.enum))
        case .struct:
            return .swift(.type(.struct))
        case .class:
            return .swift(.type(.class))
        }
    }
}
