public import Combine
import Foundation
import FoundationToolbox
import RuntimeViewerCommunication

// MARK: - Owners

extension RuntimeEngine {
    /// The engines this one borrows shared cache images from, or `nil` while
    /// it serves every image itself. See `RuntimeSharedCacheOwners`.
    public nonisolated var sharedCacheOwners: RuntimeSharedCacheOwners? {
        sharedCacheOwnersSubject.value
    }

    /// Emits the owners each time they change, the current ones first.
    public nonisolated var sharedCacheOwnersPublisher: some Publisher<RuntimeSharedCacheOwners?, Never> {
        sharedCacheOwnersSubject.removeDuplicates()
    }

    /// From now on this engine hands every request about one of `owners`'
    /// images to the image's owner, and serves only the rest itself; `nil`
    /// makes it serve every image again. Set by the engine manager.
    ///
    /// A request already under way is not moved. The images an owner loaded
    /// for this engine are forgotten when the owners change: they were the
    /// old owners' loads.
    public func setSharedCacheOwners(_ owners: RuntimeSharedCacheOwners?) {
        guard sharedCacheOwnersSubject.value != owners else { return }
        borrowedLoadedImagePaths.removeAll()
        sharedCacheOwnersSubject.value = owners
        RuntimeEngineSharedCacheLog.ownersChanged(of: source, to: owners)
    }

    /// Whether a request about the image at `imagePath` goes to an owner.
    public nonisolated func borrowsSharedCacheImage(at imagePath: String) -> Bool {
        sharedCacheOwner(forImageAt: imagePath) != nil
    }

    /// The owner a request about `imagePath` goes to: `nil` for no image, an
    /// image no owner keeps, and an image this engine owns itself.
    nonisolated func sharedCacheOwner(forImageAt imagePath: String?) -> RuntimeEngine? {
        guard let imagePath,
              let owners = sharedCacheOwnersSubject.value,
              let owner = owners.owner(ofImageAt: canonicalImagePath(imagePath)),
              owner !== self
        else { return nil }
        return owner
    }
}

// MARK: - Serving a borrowed request

extension RuntimeEngine {
    /// Serves a request another engine handed over because this engine owns
    /// its subject image: dispatched to this engine's serving process, never
    /// on to owners of this engine's own — the owner of an image owns it —
    /// and with what a window on this engine making the request would have
    /// caused here too. A load made for the user holds back this engine's
    /// background indexing, which competes for the same process, and an image
    /// indexed by the request is announced on this engine's
    /// `imageDidIndexPublisher`, which its corpus and cross-reference work
    /// listens to.
    func dispatchBorrowedRequest<Command: RuntimeEngineCommand>(_ command: Command) async throws -> Command.Response {
        let response = if Command.isForegroundLoad {
            try await performingForegroundLoad {
                try await dispatchToServingProcess(command)
            }
        } else {
            try await dispatchToServingProcess(command)
        }
        announceIndexedSubjectImage(of: command)
        return response
    }

    /// `dispatchBorrowedRequest(_:)` for a request that reports progress.
    func dispatchBorrowedRequest<Command: RuntimeEngineProgressCommand>(
        _ command: Command,
        onProgress: (@Sendable (Command.Progress) async -> Void)?
    ) async throws -> Command.Response {
        let response = if Command.isForegroundLoad {
            try await performingForegroundLoad {
                try await dispatchToServingProcess(command, onProgress: onProgress)
            }
        } else {
            try await dispatchToServingProcess(command, onProgress: onProgress)
        }
        announceIndexedSubjectImage(of: command)
        return response
    }

    private func announceIndexedSubjectImage<Command: RuntimeEngineCommand>(of command: Command) {
        guard Command.indexesSubjectImage, let imagePath = command.subjectImagePath else { return }
        imageDidIndexSubject.send(imagePath)
    }
}

// MARK: - Loading borrowed images

extension RuntimeEngine {
    /// A shared cache image an owner loaded for this engine counts as loaded
    /// on it from now on. The serving process loaded nothing and sends no
    /// reload, so the engine tells its own observers — the sidebar showing
    /// the image as not loaded yet among them — the way a load in the serving
    /// process would have.
    func noteBorrowedLoad(ofImageAt imagePath: String) {
        guard sharedCacheOwner(forImageAt: imagePath) != nil else { return }
        borrowedLoadedImagePaths.insert(canonicalImagePath(imagePath))
        dataChangeSubject.send(.fullReload(isReloadImageNodes: false))
    }

    /// An owner lists only the objects of an image it has loaded itself. When
    /// this engine is asked for the objects of a borrowed image the owner has
    /// not loaded — one the serving process has loaded and so shows as
    /// loaded, typically — the owner loads it first, reporting the indexing
    /// that comes with loading through `onProgress`.
    func loadBorrowedImageIfNeeded(
        at imagePath: String,
        onProgress: (@Sendable (RuntimeObjectsLoadingProgress) async -> Void)?
    ) async throws {
        guard let owner = sharedCacheOwner(forImageAt: imagePath),
              try await !owner.isImageLoaded(path: imagePath)
        else { return }
        if let onProgress {
            try await owner.loadImage(at: imagePath, onProgress: onProgress)
        } else {
            try await owner.loadImage(at: imagePath)
        }
    }

    /// `loadImage(at:)` in the process that serves this engine, a shared cache
    /// image an owner keeps included: what Load Frameworks… asks for — the
    /// framework loaded into this engine's process. The owner still answers
    /// for a borrowed image's data.
    public func loadImageInServingProcess(at path: String) async throws {
        try await performingForegroundLoad {
            _ = try await dispatchToServingProcess(LoadImageCommand(path: path))
        }
        imageDidIndexSubject.send(path)
    }
}

// MARK: - Logging

/// This file's log lines. `@Loggable`'s generated logger is private to the
/// file that declares it, so `RuntimeEngine.swift`'s cannot be used here.
@Loggable(.private)
private enum RuntimeEngineSharedCacheLog {
    static func ownersChanged(of source: RuntimeSource, to owners: RuntimeSharedCacheOwners?) {
        if let owners {
            #log(.info, "\(String(describing: source), privacy: .public) borrows shared cache images from \(owners.engines.map { String(describing: $0.source) }.joined(separator: ", "), privacy: .public)")
        } else {
            #log(.info, "\(String(describing: source), privacy: .public) serves every image itself")
        }
    }
}
