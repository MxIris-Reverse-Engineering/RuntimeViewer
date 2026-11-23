import Foundation

/// Where the SDK type index of the process serving an engine stands, per SDK
/// platform it was asked about — what the Report navigator's Imported Type
/// Names rows show. Answered by `RuntimeEngine.typeIndexStatus()`; an engine
/// whose serving process has no type index (an iOS device, an injected
/// process, an older peer) answers `.empty`.
public struct RuntimeTypeIndexStatus: Codable, Sendable, Hashable {
    public enum UnavailabilityReason: String, Codable, Sendable, Hashable {
        /// No developer directory is selected on the serving Mac.
        case noDeveloperDirectory
        /// The developer directory has no SDK for the platform — the Command
        /// Line Tools carry the macOS SDK only.
        case sdkNotInstalled
    }

    public enum Phase: Codable, Sendable, Hashable {
        /// Batches are queued: API notes, or the modules newly opened images
        /// link. Interfaces print `__C.` names until the first one finishes.
        case building(finishedBatchCount: Int, queuedBatchCount: Int)
        /// Everything asked for is indexed.
        case ready
        /// The serving Mac cannot index the platform.
        case unavailable(UnavailabilityReason)
    }

    public struct PlatformStatus: Codable, Sendable, Hashable {
        /// The SDK platform's `xcrun --sdk` style name (`macosx`,
        /// `maccatalyst`, `iphoneos`).
        public let platformName: String
        /// The SDK's version and build (`27.2-27C5`), when it is installed.
        public let sdkVersion: String?
        public let phase: Phase
        /// How many SDK modules' interfaces were asked for.
        public let indexedModuleCount: Int

        public init(platformName: String, sdkVersion: String?, phase: Phase, indexedModuleCount: Int) {
            self.platformName = platformName
            self.sdkVersion = sdkVersion
            self.phase = phase
            self.indexedModuleCount = indexedModuleCount
        }
    }

    public let platforms: [PlatformStatus]
    /// The size of the module-interface cache on disk, shared by every
    /// process of the application.
    public let cacheByteCount: Int64

    public init(platforms: [PlatformStatus], cacheByteCount: Int64) {
        self.platforms = platforms
        self.cacheByteCount = cacheByteCount
    }

    public static let empty = RuntimeTypeIndexStatus(platforms: [], cacheByteCount: 0)

    /// Whether a batch is queued on any platform.
    public var isBuilding: Bool {
        platforms.contains {
            if case .building = $0.phase { true } else { false }
        }
    }
}
