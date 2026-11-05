import Foundation
import FoundationToolbox
import MachO.dyld
import MachOKit
import SwiftDeclarationRendering

public struct DyldOpenError: Error {
    public let message: String?
}
