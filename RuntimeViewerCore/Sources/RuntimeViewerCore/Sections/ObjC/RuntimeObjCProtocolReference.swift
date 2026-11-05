import Foundation
import FoundationToolbox
import MachOKit
import ObjCIndexing
import OrderedCollections

/// An Objective-C protocol found to adopt (refine) another protocol, paired
/// with the image declaring it. Same in-process-only status as
/// `RuntimeObjCClassReference`.
struct RuntimeObjCProtocolReference: Hashable, Sendable {
    let protocolName: String
    let imagePath: String
}
