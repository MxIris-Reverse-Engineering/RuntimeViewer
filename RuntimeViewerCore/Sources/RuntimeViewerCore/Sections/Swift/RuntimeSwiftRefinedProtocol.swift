import SwiftDeclaration
@_spi(Support) import SwiftIndexing
import Demangling
import Foundation
import MachOKit
import MachOSwiftSection
import OrderedCollections
import SwiftStdlibToolbox
@_spi(Internals) import SwiftInspection
@_spi(Support) import SwiftInterface
@_spi(Support) import SwiftSpecialization

/// A protocol named in another protocol's requirement signature as a base
/// conformance: a Swift protocol by qualified name, or an Objective-C
/// protocol by its runtime name (`isObjC`), which the ObjC tables resolve.
struct RuntimeSwiftRefinedProtocol: Hashable, Sendable {
    let qualifiedName: String
    let isObjC: Bool
}
