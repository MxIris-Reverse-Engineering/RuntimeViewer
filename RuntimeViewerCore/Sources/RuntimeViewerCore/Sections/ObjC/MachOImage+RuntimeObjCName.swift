import Foundation
import FoundationToolbox
import MachOObjCSection
import ObjCDump
import ObjCTypeDecodeKit
import OrderedCollections
private import RuntimeViewerObjC
import Semantic
import SwiftInspection
import Utilities
import MetaCodable

import ObjCDeclarationRendering
import ObjCIndexing
import ObjCInterface

extension MachOImage {
    static func image(forName name: RuntimeObjCName) -> Self? {
        switch name {
        case .class(let string):
            return .image(forClassName: string)
        case .protocol(let string):
            return .image(forProtocolName: string)
        }
    }

    static func image(forClassName className: String) -> Self? {
        RVClassFromString(className).flatMap { MachOImage.image(for: autoBitCast($0)) }
    }

    static func image(forProtocolName protocolName: String) -> Self? {
        RVProtocolFromString(protocolName).flatMap { MachOImage.image(for: autoBitCast($0)) }
    }
}
