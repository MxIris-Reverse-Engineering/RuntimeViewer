import Foundation
import RuntimeViewerCore

/// The language a function is written in, as far as its name tells.
public enum RuntimeFunctionLanguage: Hashable, Sendable {
    case swift
    case objectiveC
    /// Neither of the others: C, C++, a block.
    case cOrCPlusPlus

    /// The language a symbol's spelling gives away: `_$s…` and the older
    /// Swift manglings are Swift, `-[Class selector]` and `+[…]` are
    /// Objective-C methods, and the rest — `_CFRelease`, `__ZN…`, a block — is
    /// C or C++.
    public init(symbol: String) {
        let name = symbol.hasPrefix("_") ? symbol.dropFirst() : Substring(symbol)
        if name.hasPrefix("$s") || name.hasPrefix("$S") || name.hasPrefix("$e") || name.hasPrefix("_T0") {
            self = .swift
        } else if symbol.hasPrefix("-[") || symbol.hasPrefix("+[") {
            self = .objectiveC
        } else {
            self = .cOrCPlusPlus
        }
    }
}
