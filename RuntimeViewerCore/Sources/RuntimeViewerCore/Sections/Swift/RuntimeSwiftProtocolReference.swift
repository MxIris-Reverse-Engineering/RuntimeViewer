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

/// A Swift protocol paired with the image declaring it, addressed both by
/// the qualified name the indexer keys protocols by and by the mangled name
/// a `RuntimeObject` carries.
struct RuntimeSwiftProtocolReference: Hashable, Sendable {
    let qualifiedName: String
    let mangledName: String
    let imagePath: String
}
