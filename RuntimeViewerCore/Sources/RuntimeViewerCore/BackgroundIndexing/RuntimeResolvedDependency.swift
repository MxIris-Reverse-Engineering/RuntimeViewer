public struct RuntimeResolvedDependency: Sendable, Hashable {
    public let installName: String
    public let resolvedPath: String?

    public init(installName: String, resolvedPath: String?) {
        self.installName = installName
        self.resolvedPath = resolvedPath
    }
}
