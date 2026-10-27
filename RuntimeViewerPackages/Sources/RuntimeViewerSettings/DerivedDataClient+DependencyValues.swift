import Dependencies
import DependenciesMacros

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { DerivedDataClient() })
    public var derivedDataClient: DerivedDataClient
}
