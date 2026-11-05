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

extension [SemanticString] {
    func join(separator: SemanticString = "") -> Element {
        var result: SemanticString = ""
        for (index, element) in enumerated() {
            result.append(element)
            if index < count - 1 {
                result.append(separator)
            }
        }
        return result
    }
}
