import Foundation
import Observation
import Dependencies
import DependenciesMacros
import RuntimeViewerEngineManagement
import RuntimeViewerSettings

/// Writes the settings the engine manager takes into it — Settings ›
/// Developer's shared cache switch — from the stored values on, and every
/// change after: the part of the settings lifecycle the macOS app and the
/// iOS-family apps share. Each app's settings lifecycle controller starts it
/// once the stored settings are read: loading replaces the object an earlier
/// start would have followed.
@MainActor
public final class RuntimeEngineManagerSettingsFollower {
    fileprivate static let shared = RuntimeEngineManagerSettingsFollower()

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    @Dependency(\.settings) private var settings

    private var isFollowing = false

    init() {}

    /// Starts following. Calling it again does nothing.
    public func startFollowing() {
        guard !isFollowing else { return }
        isFollowing = true
        follow()
    }

    private func follow() {
        withObservationTracking {
            runtimeEngineManager.sharesSharedCacheImages = settings.developer.effectiveSharesSharedCacheImages
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.follow()
            }
        }
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeEngineManagerSettingsFollower.shared })
    public var runtimeEngineManagerSettingsFollower: RuntimeEngineManagerSettingsFollower
}
