#if os(macOS)

import Foundation
import FoundationToolbox
import ObjCDeclarationRendering
import ObjCTypeIndexing
import SwiftTypeNameResolution
import TypeIndexing

/// This process's SDK type index (swift-type-indexing): what resolves
/// `__C.UICellConfigurationState` to `UIKit.__UICellConfigurationState` in a
/// Swift interface, and gives an Objective-C header the SDK's
/// `NS_SWIFT_NAME(...)` / `NS_REFINED_FOR_SWIFT` (proposal
/// `swift-type-indexing-package` in MachOSwiftSection).
///
/// One `TypeDatabase` per SDK platform, built in the process that prints —
/// the local, Mac Catalyst, file and framework services and the command-line
/// host. Work comes in batches, one platform's at a time and in order: the
/// first batch of a platform reads its API notes (about two seconds), and
/// each image adds the modules it links (sourcekitd; the first time for
/// UIKit, about two minutes, cached on disk after). A finished batch bumps the
/// platform's generation, which the Swift sections compare to re-register
/// their resolver and drop their printed interfaces, and tells the listeners,
/// which broadcast `RuntimeDataChange.typeNamesResolved` to the app.
///
/// Not behind `@Dependency`, as project singletons otherwise are:
/// `RuntimeViewerCore` does not depend on swift-dependencies, and nothing
/// but the engine and the sections reaches it (as `RuntimeDerivedData`).
@available(macOS 13.0, *)
actor RuntimeTypeIndex {
    /// The process's index, keeping its module-interface cache in the
    /// application's caches (`RuntimeTypeIndexLocation`).
    static let process = RuntimeTypeIndex(cacheDirectoryURL: RuntimeTypeIndexLocation.cacheDirectoryURL(forProcessBundle: .main))

    /// A database and what it has done, per platform.
    private struct PlatformState {
        let availability: TypeIndexingAvailability
        let typeDatabase: TypeDatabase
        /// The modules a batch was queued for, so a module is indexed once.
        var requestedModuleNames: Set<String> = []
        /// Image paths whose metadata a batch was queued with.
        var requestedImagePaths: Set<String> = []
        /// The last queued batch; the next one waits for it.
        var lastBatch: Task<Void, Never>?
        var queuedBatchCount = 0
        var finishedBatchCount = 0
        /// Bumped when a batch finishes; `nil` until the first one does.
        var generation: Int?
    }

    private let cacheDirectoryURL: URL?

    private var statesByPlatform: [SDKPlatform: PlatformState] = [:]

    /// Platforms this Mac cannot index, and why.
    private var unavailablePlatforms: [SDKPlatform: TypeIndexingAvailability] = [:]

    private var listenersByIdentifier: [UUID: @Sendable (SDKPlatform) -> Void] = [:]

    init(cacheDirectoryURL: URL?) {
        self.cacheDirectoryURL = cacheDirectoryURL
    }

    // MARK: - Requests

    /// Queues the modules an image links, and the image's own Objective-C
    /// metadata, behind whatever the platform already has queued, and returns
    /// the task that finishes with them — or the last queued one when there
    /// is nothing new. `nil` when this Mac cannot index the platform.
    @discardableResult
    func request(_ request: RuntimeTypeIndexRequest) -> Task<Void, Never>? {
        guard RuntimeTypeNames.isEnabledInThisProcess, var state = state(for: request.platform) else { return nil }
        let newModuleNames = request.moduleNames.subtracting(state.requestedModuleNames)
        let newSources = request.metadataSources.filter { !state.requestedImagePaths.contains($0.imagePath) }
        let isFirstBatch = state.lastBatch == nil
        guard isFirstBatch || !newModuleNames.isEmpty || !newSources.isEmpty else {
            return state.lastBatch
        }
        state.requestedModuleNames.formUnion(newModuleNames)
        state.requestedImagePaths.formUnion(newSources.map(\.imagePath))
        state.queuedBatchCount += 1
        let platform = request.platform
        let typeDatabase = state.typeDatabase
        let previousBatch = state.lastBatch
        // Isolated to this actor, as the method that makes it.
        let batch = Task {
            await previousBatch?.value
            do {
                try await typeDatabase.index(dependencies: newSources, moduleFilter: { newModuleNames.contains($0) })
            } catch {
                logBatchFailure(platform: platform, error: error)
            }
            finishBatch(of: platform)
        }
        state.lastBatch = batch
        statesByPlatform[platform] = state
        return batch
    }

    /// Waits until everything queued for `platform` so far is indexed.
    /// Returns at once when the platform cannot be indexed.
    func waitUntilSettled(_ platform: SDKPlatform) async {
        await statesByPlatform[platform]?.lastBatch?.value
    }

    private func finishBatch(of platform: SDKPlatform) {
        guard var state = statesByPlatform[platform] else { return }
        state.finishedBatchCount += 1
        state.generation = (state.generation ?? 0) + 1
        statesByPlatform[platform] = state
        for listener in listenersByIdentifier.values {
            listener(platform)
        }
    }

    private func logBatchFailure(platform: SDKPlatform, error: any Error) {
        #log(.error, "Type index batch for \(platform.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }

    private func state(for platform: SDKPlatform) -> PlatformState? {
        if let state = statesByPlatform[platform] {
            return state
        }
        if unavailablePlatforms[platform] != nil {
            return nil
        }
        let availability = TypeIndexingAvailability.availability(for: platform)
        guard availability.isAvailable else {
            #log(.default, "No type index for \(platform.rawValue, privacy: .public): \(String(describing: availability.unavailabilityReason), privacy: .public)")
            unavailablePlatforms[platform] = availability
            return nil
        }
        let state = PlatformState(
            availability: availability,
            typeDatabase: TypeDatabase(platform: platform, cacheDirectory: cacheDirectoryURL)
        )
        statesByPlatform[platform] = state
        return state
    }

    // MARK: - Answers

    /// The resolver a printer registers for `platform`, and the generation it
    /// stands for; `nil` until the platform's first batch finished.
    func resolution(for platform: SDKPlatform) -> (resolver: TypeDatabaseTypeNameResolver, generation: Int)? {
        guard let state = statesByPlatform[platform], let generation = state.generation else { return nil }
        return (TypeDatabaseTypeNameResolver(typeDatabase: state.typeDatabase), generation)
    }

    /// The generation of `platform`'s index; `nil` until its first batch
    /// finished.
    func generation(of platform: SDKPlatform) -> Int? {
        statesByPlatform[platform]?.generation
    }

    /// What the SDK's API notes say about the Objective-C class or protocol
    /// `object` names, or a category's class; empty until the platform's
    /// first batch finished.
    func swiftImportNotes(forClassNamed className: String, platform: SDKPlatform) async -> ObjCSwiftImportNotes {
        guard let state = statesByPlatform[platform], state.generation != nil else { return ObjCSwiftImportNotes() }
        return await ObjCSwiftImportNotes(apiNotesForClassNamed: className, in: state.typeDatabase)
    }

    func swiftImportNotes(forProtocolNamed protocolName: String, platform: SDKPlatform) async -> ObjCSwiftImportNotes {
        guard let state = statesByPlatform[platform], state.generation != nil else { return ObjCSwiftImportNotes() }
        return await ObjCSwiftImportNotes(apiNotesForProtocolNamed: protocolName, in: state.typeDatabase)
    }

    /// Where every platform asked for stands.
    func status() -> RuntimeTypeIndexStatus {
        var platformStatuses: [RuntimeTypeIndexStatus.PlatformStatus] = []
        for (platform, state) in statesByPlatform {
            let phase: RuntimeTypeIndexStatus.Phase = state.finishedBatchCount < state.queuedBatchCount
                ? .building(finishedBatchCount: state.finishedBatchCount, queuedBatchCount: state.queuedBatchCount)
                : .ready
            platformStatuses.append(.init(platformName: platform.rawValue, sdkVersion: state.availability.sdkSettings?.cacheDirectoryComponent, phase: phase, indexedModuleCount: state.requestedModuleNames.count))
        }
        for (platform, availability) in unavailablePlatforms {
            let reason: RuntimeTypeIndexStatus.UnavailabilityReason = switch availability.unavailabilityReason {
            case .noDeveloperDirectory, nil: .noDeveloperDirectory
            case .sdkNotInstalled: .sdkNotInstalled
            }
            platformStatuses.append(.init(platformName: platform.rawValue, sdkVersion: nil, phase: .unavailable(reason), indexedModuleCount: 0))
        }
        return RuntimeTypeIndexStatus(
            platforms: platformStatuses.sorted { $0.platformName < $1.platformName },
            cacheByteCount: cacheDirectoryURL.map(RuntimeTypeIndexLocation.allocatedByteCount(at:)) ?? 0
        )
    }

    // MARK: - Listeners

    /// Calls `listener` with a platform each time a batch of it finishes,
    /// until the returned token is passed to `removeListener(_:)`.
    func addListener(_ listener: @escaping @Sendable (SDKPlatform) -> Void) -> UUID {
        let identifier = UUID()
        listenersByIdentifier[identifier] = listener
        return identifier
    }

    func removeListener(_ identifier: UUID) {
        listenersByIdentifier[identifier] = nil
    }
}

/// What an image asks of the type index: its platform, the SDK modules it
/// links, and its own Objective-C metadata for the private types no SDK file
/// names.
@available(macOS 13.0, *)
struct RuntimeTypeIndexRequest: Sendable {
    let platform: SDKPlatform
    let moduleNames: Set<String>
    let metadataSources: [any DeclaredTypeNameSource]
}

// Protocol-form `@Loggable`: the actor carries an `@available(macOS 13.0, *)`
// scope the direct form's static logger would exceed.
@Loggable(.fileprivate)
fileprivate protocol RuntimeTypeIndexLogging {}

@available(macOS 13.0, *)
extension RuntimeTypeIndex: RuntimeTypeIndexLogging {}

#endif
