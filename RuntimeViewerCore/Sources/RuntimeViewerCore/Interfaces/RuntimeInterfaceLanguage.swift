import Foundation

/// The language an interface is written in. Named after DocC's
/// `interfaceLanguage`, and spelled with its identifiers: `occ` for
/// Objective-C, `swift` for Swift.
///
/// A string rather than an enum, so that a peer that knows fewer languages
/// still decodes one it does not know, and can tell that it is not one of its
/// own.
public struct RuntimeInterfaceLanguage: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// An Objective-C header, as the runtime metadata reads.
    public static let objectiveC = RuntimeInterfaceLanguage(rawValue: "occ")

    /// A Swift declaration — of a Swift object, or of an Objective-C one as
    /// Swift imports it.
    public static let swift = RuntimeInterfaceLanguage(rawValue: "swift")
}
