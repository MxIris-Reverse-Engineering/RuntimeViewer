public struct RuntimeObjectName: Codable, Hashable, Identifiable {
    public let name: String
    public let kind: RuntimeObjectKind
    public let imagePath: String
    public var id: Self { self }
}

extension RuntimeObjectName: ComparableBuildable {
    public static let comparableDefinition = makeComparable {
        compare(\.imagePath)
        compare(\.kind)
        compare(\.name)
    }
}
