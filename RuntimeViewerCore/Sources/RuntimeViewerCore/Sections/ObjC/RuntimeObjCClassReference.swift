import Foundation
import FoundationToolbox
import MachOKit
import ObjCIndexing
import OrderedCollections

/// An Objective-C class — or a Swift class carrying an Objective-C ancestor —
/// found to subclass another class or to adopt a protocol.
///
/// `isSwiftStable` is the structural signal (`class_t`'s `FAST_IS_SWIFT_STABLE`
/// bit) that lets `RuntimeRelationshipsResolver` decide whether to materialize
/// the reference as a Swift `RuntimeObject` or an Objective-C one. The library
/// reports the bit; the domain judgement is made here.
///
/// Deliberately neither `public` nor `Codable`: relationship references never
/// leave the process. What crosses the XPC boundary is the already-materialized
/// `RuntimeObject`.
struct RuntimeObjCClassReference: Hashable, Sendable {
    let className: String
    let imagePath: String
    let isSwiftStable: Bool
}
