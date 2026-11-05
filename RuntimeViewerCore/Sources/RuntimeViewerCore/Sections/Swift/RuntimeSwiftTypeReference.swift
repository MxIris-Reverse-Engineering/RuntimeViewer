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

/// A Swift type found to subclass another type or to conform to a protocol,
/// paired with the image that named it.
///
/// The Swift counterpart of `RuntimeObjCClassReference`. There is no
/// `isSwiftStable` here: a type reached through the Swift tables is a Swift type
/// by construction, whereas the ObjC tables carry both and have to say which.
///
/// Deliberately neither `public` nor `Codable`, for the same reason as the ObjC
/// one: relationship references never leave the process — what crosses the XPC
/// boundary is the already-materialized `RuntimeObject`.
struct RuntimeSwiftTypeReference: Hashable, Sendable {
    let mangledName: String
    let imagePath: String
}
