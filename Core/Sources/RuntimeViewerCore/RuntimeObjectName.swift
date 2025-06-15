public struct RuntimeObjectName: Codable, Hashable, Identifiable {
    public let name: String
    public let kind: RuntimeObjectKind
    public var id: Self { self }
}
