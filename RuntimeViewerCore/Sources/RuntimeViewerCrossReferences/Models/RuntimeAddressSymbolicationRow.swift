/// One symbolicated address as the command line's `--json` and the MCP tool
/// report it: flat, addresses as hexadecimal strings. The one place these
/// field names are spelled, like ``RuntimeCrossReferenceRow``.
public struct RuntimeAddressSymbolicationRow: Hashable, Codable, Sendable {
    public let address: String
    public let imagePath: String?
    public let imageName: String?
    public let segmentName: String?
    public let sectionName: String?
    /// ``RuntimeAddressSymbolication/Kind``: `function`, `stub`,
    /// `pointerSlot`, `cString`, `constantString`, `symbol`, `data` or
    /// `unmapped`.
    public let kind: String
    /// The function the address lies in, when it lies in one.
    public let functionAddress: String?
    public let functionName: String?
    /// How far into the function, or past the symbol.
    public let offset: String?
    /// What lies there, in words.
    public let summary: String

    public init(_ symbolication: RuntimeAddressSymbolication) {
        self.address = RuntimeCrossReferenceRow.hexadecimal(symbolication.address)
        self.imagePath = symbolication.imagePath
        self.imageName = symbolication.imagePath.map(RuntimeCrossReferenceRow.imageName(ofPath:))
        self.segmentName = symbolication.segmentName
        self.sectionName = symbolication.sectionName
        self.kind = symbolication.kind.rawValue
        self.functionAddress = symbolication.function.map { RuntimeCrossReferenceRow.hexadecimal($0.address) }
        self.functionName = symbolication.function.flatMap { $0.displayName ?? $0.symbolName }
        self.offset = symbolication.offset.map(RuntimeCrossReferenceRow.hexadecimal)
        self.summary = symbolication.summary
    }
}
