import Dependencies

private enum UpdaterClientKey: @preconcurrency DependencyKey {
    @MainActor static let liveValue = UpdaterClient()
}

extension DependencyValues {
    public var updaterClient: UpdaterClient {
        get { self[UpdaterClientKey.self] }
        set { self[UpdaterClientKey.self] = newValue }
    }
}
