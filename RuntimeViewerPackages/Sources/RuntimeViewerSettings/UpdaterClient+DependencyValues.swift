import Dependencies
import DependenciesMacros

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { UpdaterClient() })
    public var updaterClient: UpdaterClient
}
