/// Where an image the engine's process maps defines a symbol.
public struct RuntimeSymbolLocation: Hashable, Codable, Sendable {
    public let imagePath: String
    /// Unslid.
    public let address: UInt64

    public init(imagePath: String, address: UInt64) {
        self.imagePath = imagePath
        self.address = address
    }
}
