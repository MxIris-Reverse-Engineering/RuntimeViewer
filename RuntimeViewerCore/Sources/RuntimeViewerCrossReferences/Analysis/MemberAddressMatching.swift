import Foundation
import FoundationToolbox
import MachO
import RuntimeViewerCore
import CrossReferenceAnalysis

/// Picks a member's rows out of `RuntimeEngine.memberAddresses(for:memberName:)`,
/// which matches names loosely — it serves a search box.
enum MemberAddressMatching {
    static func matches(_ memberAddress: RuntimeMemberAddress, _ member: RuntimeMemberReference) -> Bool {
        let kind = memberAddress.kind
        switch member.kind {
        case .objcMethod:
            return memberAddress.name == member.name && kind == (member.isStatic ? "class method" : "method")
        case .objcProperty:
            return memberAddress.name == member.name && kind.hasPrefix(member.isStatic ? "class property " : "property ")
        case .swiftFunction:
            return memberAddress.name == member.name && kind == (member.isStatic ? "static func" : "func")
        case .swiftInitializer:
            // The member list names every initializer `init`; the rows carry
            // the definitions' own names.
            return kind == "init" || kind == "allocator"
        case .swiftVariable:
            let (isStatic, accessor) = split(kind)
            return memberAddress.name == member.name && isStatic == member.isStatic
                && !["func", "init", "allocator"].contains(accessor) && !accessor.hasPrefix("subscript.")
        case .swiftSubscript:
            let (isStatic, accessor) = split(kind)
            return isStatic == member.isStatic && accessor.hasPrefix("subscript.")
        case .objcIvar, .swiftField, .swiftEnumCase:
            // Storage, not code.
            return false
        }
    }

    /// The unslid address a row prints as hexadecimal.
    static func address(of memberAddress: RuntimeMemberAddress) -> UInt64? {
        var digits = Substring(memberAddress.address)
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits = digits.dropFirst(2) }
        return UInt64(digits, radix: 16)
    }

    private static func split(_ kind: String) -> (isStatic: Bool, rest: Substring) {
        kind.hasPrefix("static ") ? (true, kind.dropFirst("static ".count)) : (false, Substring(kind))
    }
}
