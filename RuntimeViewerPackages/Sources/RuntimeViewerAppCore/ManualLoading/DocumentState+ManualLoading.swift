import Foundation
import RuntimeViewerCore

extension DocumentState {
    /// Runs `work` as the user's own load of the image at `imagePath`, which the Report navigator's
    /// Manual Loading lists while it runs and once it ended (proposal `editor-jump-bar`) — under the
    /// engine whose background work keeps the image's data, so a shared cache image the engine
    /// borrows is recorded under its owner, where its loading happens. `work` reports its progress
    /// through the function it is given.
    ///
    /// Hand it only loads that do something — an image to load, or one to index — not one that
    /// answers from what is indexed already, or the Report fills with rows of nothing. A document
    /// holding no background work runs `work` without recording it.
    public func recordingManualLoad<Result: Sendable>(
        ofImageAt imagePath: String,
        _ work: @escaping @Sendable (_ reportProgress: @escaping @Sendable (RuntimeObjectsLoadingProgress) async -> Void) async throws -> Result
    ) async throws -> Result {
        guard let manualImageLoadCoordinator = runtimeEngineSession.backgroundWork(forImageAt: imagePath)?.manualImageLoadCoordinator else {
            return try await work { _ in }
        }
        return try await manualImageLoadCoordinator.record(loadOfImageAt: imagePath, work)
    }

    /// Indexes the image at `imagePath` for the user the way the sidebar opens one — loading it
    /// first when the engine's process has not — unless it is indexed already, recorded in Manual
    /// Loading when there is work to do.
    public func indexImageForUser(at imagePath: String) async throws {
        let runtimeEngine = runtimeEngine
        guard try await !runtimeEngine.isImageIndexed(path: imagePath) else { return }
        try await recordingManualLoad(ofImageAt: imagePath) { reportProgress in
            try await runtimeEngine.indexImageIfNeeded(at: imagePath, reportProgress: reportProgress)
        }
    }
}
