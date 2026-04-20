import MachOKit
import MachOExtensions
import Semantic

extension MachOImage {
    /// Safely format an IMP address into a resolved virtual address string.
    ///
    /// Returns `nil` when the raw value is zero or falls below the image base,
    /// meaning the caller should treat it as invalid.
    func formattedAddress(forRawValue rawValue: UInt64) -> String? {
        let value = UInt(rawValue)
        let baseAddress = UInt(bitPattern: ptr)
        guard value != 0, value >= baseAddress else {
            return nil
        }
        return "0x\(addressString(forOffset: .init(value &- baseAddress)))"
    }

    /// Build a ``Comment`` component for an IMP address.
    ///
    /// Produces a normal comment (e.g. `// IMP: 0x1A2B3C`) when the address
    /// is valid, or an ``Error`` component (e.g. `// IMP: <invalid 0x0>`)
    /// when it is not.
    @SemanticStringBuilder
    func impAddressComment(label: String, rawValue: UInt64) -> SemanticString {
        if let resolved = formattedAddress(forRawValue: rawValue) {
            Comment("\(label): \(resolved)")
        } else {
            Comment("\(label): ")
            Error("<invalid 0x\(String(UInt(rawValue), radix: 16, uppercase: true))>")
        }
    }

    /// Format an IMP address into a plain string suitable for data models.
    ///
    /// Returns a resolved virtual address when valid, or a raw hex
    /// representation prefixed with `<invalid>` when not.
    func formattedAddressString(forRawValue rawValue: UInt64) -> String {
        if let resolved = formattedAddress(forRawValue: rawValue) {
            return resolved
        }
        return "<invalid 0x\(String(UInt(rawValue), radix: 16, uppercase: true))>"
    }
}
