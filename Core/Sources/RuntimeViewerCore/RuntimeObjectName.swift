public struct RuntimeObjectName: Codable, Hashable, Identifiable {
    public let name: String
    public let kind: RuntimeObjectKind
    public let imagePath: String
    public var id: Self { self }
}

extension RuntimeObjectName: Comparable {
    public static func < (lhs: RuntimeObjectName, rhs: RuntimeObjectName) -> Bool {
        lhs.name < rhs.name
    }
}
