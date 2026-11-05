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

enum RuntimeObjCName {
    case `class`(String)
    case `protocol`(String)
}
