import Foundation

public struct RuntimeMemberAddress: Sendable, Codable {
    /// The human-readable member name (e.g. "myFunc(arg:)", "myProperty")
    public let name: String
    /// The member kind (e.g. "func", "static func", "init", "allocator", "getter", "setter", "subscript.getter")
    public let kind: String
    /// The mangled symbol name (e.g. "$s9MyModule9MyClassC6myFuncyyF")
    public let symbolName: String
    /// The runtime address in hex format (e.g. "0x100123ABC")
    public let address: String

    public init(name: String, kind: String, symbolName: String, address: String) {
        self.name = name
        self.kind = kind
        self.symbolName = symbolName
        self.address = address
    }
}
