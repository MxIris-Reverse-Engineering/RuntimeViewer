#if os(macOS)

import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerSettings
import RuntimeViewerEngineManagement

/// What a file engine's file can read its dependencies from, as the runtime source picker's
/// Dependency Cache level lists it, and the pairing a choice there does.
@Loggable
@MainActor
enum RuntimeFileDependencyCaches {
    /// What `engine`'s file can read its dependencies from: this Mac's cache
    /// for a macOS or Mac Catalyst file, the registered caches of its
    /// platform, and nothing — the file alone. A folder, which can hold
    /// binaries of several platforms, is offered this Mac's cache and every
    /// registered one, each named with its platform. Empty for a dyld shared
    /// cache, which is its own, and for an engine that reads no file.
    static func choices(
        for engine: RuntimeEngine,
        runtimeEngineManager: RuntimeEngineManager,
        settings: SettingsAccess
    ) -> [RuntimeSourcePickerContent.DependencyCacheChoice] {
        guard let file = runtimeEngineManager.file(of: engine) else { return [] }
        if case .dyldSharedCache = file.content { return [] }
        var choices: [RuntimeSourcePickerContent.DependencyCacheChoice] = []
        if Settings.File.canPairWithThisMacsCache(file) {
            choices.append(.init(title: "This Mac's Dyld Shared Cache", dependencyCache: .systemDyldSharedCache, isCurrent: file.dependencyCache == .systemDyldSharedCache))
        }
        let namesPlatforms = file.content == .folder
        for cache in settings.file.dependencyCaches(for: file) {
            let dependencyCache = RuntimeFile.DependencyCache.dyldSharedCache(URL(fileURLWithPath: cache.path))
            let version = namesPlatforms ? "\(cache.platformName) \(cache.version)" : cache.version
            choices.append(.init(title: "\(version) (\(cache.architecture)) — \(URL(fileURLWithPath: cache.path).deletingLastPathComponent().lastPathComponent)", dependencyCache: dependencyCache, isCurrent: file.dependencyCache == dependencyCache))
        }
        choices.append(.init(title: "None", dependencyCache: nil, isCurrent: file.dependencyCache == nil))
        return choices
    }

    /// Reads `engine`'s file again, paired with `dependencyCache`, and waits
    /// until it has. The engine stays the same object, so every window on it
    /// stays, saying it is reading meanwhile; its new instance lists the
    /// images anew.
    static func pair(
        _ engine: RuntimeEngine,
        with dependencyCache: RuntimeFile.DependencyCache?,
        runtimeEngineManager: RuntimeEngineManager
    ) async throws {
        guard var file = runtimeEngineManager.file(of: engine), file.dependencyCache != dependencyCache else { return }
        file.dependencyCache = dependencyCache
        _ = try await runtimeEngineManager.runtimeEngine(reading: file)
        #log(.info, "Paired \(file.displayName, privacy: .public) with another dependency cache")
    }
}

#endif
