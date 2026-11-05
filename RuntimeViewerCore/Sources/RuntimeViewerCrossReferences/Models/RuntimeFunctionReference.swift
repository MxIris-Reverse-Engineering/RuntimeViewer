import Foundation
import RuntimeViewerCore

/// A function the analysis scanned, named or not.
///
/// More than a third of the functions in macOS 26.7's dyld shared cache carry
/// no symbol — nine in ten in some Swift frameworks; they are functions all the
/// same, with `displayName` and `symbolName` both `nil`, and a front end shows
/// them by address and image.
public struct RuntimeFunctionReference: Hashable, Codable, Sendable {
    public let imagePath: String
    /// The unslid address of the first instruction — what `dyld_info` and a
    /// disassembler print.
    public let address: UInt64
    /// As Runtime Viewer prints it: `-[NSWindow makeKeyAndOrderFront:]`,
    /// `SwiftUI.ViewGraph.updateOutputs(at:)`, `CFRelease`; `nil` when neither a
    /// symbol nor metadata names the function.
    public let displayName: String?
    /// The symbol the name came from, as the symbol table spells it:
    /// `_CFRelease`, `_$s7SwiftUI9ViewGraphC…`, `-[NSWindow makeKeyAndOrderFront:]`.
    public let symbolName: String?
    /// The member this function implements, when it maps to one.
    public let member: RuntimeMemberReference?
    /// Other symbols sharing this address because the linker folded
    /// identical code.
    public let foldedSymbolCount: Int

    public init(imagePath: String, address: UInt64, displayName: String?, symbolName: String?, member: RuntimeMemberReference?, foldedSymbolCount: Int) {
        self.imagePath = imagePath
        self.address = address
        self.displayName = displayName
        self.symbolName = symbolName
        self.member = member
        self.foldedSymbolCount = foldedSymbolCount
    }

    /// The language the function is written in, or `nil` for one nothing
    /// names. A member says so outright and a symbol by its spelling; a name
    /// with neither is one Swift metadata gave, since the Objective-C method
    /// lists name a method together with its member.
    public var language: RuntimeFunctionLanguage? {
        if let member {
            return member.kind.isObjC ? .objectiveC : .swift
        }
        if let symbolName {
            return RuntimeFunctionLanguage(symbol: symbolName)
        }
        guard let displayName else { return nil }
        return displayName.hasPrefix("-[") || displayName.hasPrefix("+[") ? .objectiveC : .swift
    }
}
