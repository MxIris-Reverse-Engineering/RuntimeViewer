import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// The images one engine's documents loaded at the user's request, for the Report navigator's
/// Manual Loading (proposal `editor-jump-bar`): the loads running now, by image, and the ones that
/// ended, newest first. Part of `RuntimeEngineBackgroundWork`, so every window on the engine shows
/// the same rows, and Clear History in one clears them for all.
///
/// It records what the call sites hand it through `DocumentState.recordingManualLoad(ofImageAt:_:)`
/// and runs nothing itself. A load is not cancelled from here — the engine cannot stop one — so the
/// rows have no Cancel. While a load runs it counts as work in progress: the Report navigator tab
/// is marked, and the app stays out of App Nap, which would otherwise slow the engine's process
/// down several times over once the user switches away.
@MainActor
final class ManualImageLoadCoordinator {
    /// How many ended loads the Report keeps; the oldest go first.
    static let historyLimit = 100

    @RxObserved
    private(set) var activeLoadsByImagePath: [String: ManualImageLoad] = [:]

    /// Newest first.
    @RxObserved
    private(set) var finishedLoads: [FinishedManualImageLoad] = []

    /// Whether a load runs, for `RuntimeEngineBackgroundWork.isWorkInProgress`.
    var hasActiveLoad: Driver<Bool> {
        $activeLoadsByImagePath.asDriver()
            .map { !$0.isEmpty }
            .distinctUntilChanged()
    }

    /// The last document on the engine left: nothing is recorded any more.
    private(set) var isClosed = false

    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Runs `work` as the user's load of the image at `imagePath`, its row in the Report while it
    /// runs, and an entry with its outcome once it ends. `work` reports its progress through the
    /// function it is given; the error it throws is rethrown.
    func record<Result: Sendable>(
        loadOfImageAt imagePath: String,
        _ work: @escaping @Sendable (_ reportProgress: @escaping @Sendable (RuntimeObjectsLoadingProgress) async -> Void) async throws -> Result
    ) async throws -> Result {
        beginLoad(ofImageAt: imagePath)
        do {
            let result = try await work { [weak self] progress in
                await MainActor.run {
                    self?.updateLoad(ofImageAt: imagePath, with: progress)
                }
            }
            endLoad(ofImageAt: imagePath, outcome: .loaded)
            return result
        } catch is CancellationError {
            endLoad(ofImageAt: imagePath, outcome: .cancelled)
            throw CancellationError()
        } catch {
            endLoad(ofImageAt: imagePath, outcome: .failed(message: Self.message(for: error)))
            throw error
        }
    }

    func clearFinishedLoads() {
        guard !finishedLoads.isEmpty else { return }
        finishedLoads = []
    }

    /// The last document on the engine left: the rows go, and loads still running are no longer
    /// recorded. They run on — the engine cannot stop them.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        activeLoadsByImagePath = [:]
        finishedLoads = []
    }

    private func beginLoad(ofImageAt imagePath: String) {
        guard !isClosed else { return }
        if var load = activeLoadsByImagePath[imagePath] {
            load.runningCount += 1
            activeLoadsByImagePath[imagePath] = load
        } else {
            activeLoadsByImagePath[imagePath] = ManualImageLoad(imagePath: imagePath, startedAt: now())
        }
    }

    private func updateLoad(ofImageAt imagePath: String, with progress: RuntimeObjectsLoadingProgress) {
        guard !isClosed, var load = activeLoadsByImagePath[imagePath] else { return }
        load.fractionCompleted = progress.overallFraction
        load.phaseDescription = progress.phase.displayDescription
        guard load != activeLoadsByImagePath[imagePath] else { return }
        activeLoadsByImagePath[imagePath] = load
    }

    /// Ends one load of the image; its row goes, with an entry for the ending, when it was the last
    /// one running.
    private func endLoad(ofImageAt imagePath: String, outcome: FinishedManualImageLoad.Outcome) {
        guard !isClosed, var load = activeLoadsByImagePath[imagePath] else { return }
        load.runningCount -= 1
        guard load.runningCount == 0 else {
            activeLoadsByImagePath[imagePath] = load
            return
        }
        activeLoadsByImagePath[imagePath] = nil
        let finishedLoad = FinishedManualImageLoad(id: UUID(), imagePath: imagePath, startedAt: load.startedAt, finishedAt: now(), outcome: outcome)
        finishedLoads = Array(([finishedLoad] + finishedLoads).prefix(Self.historyLimit))
    }

    /// What the row says went wrong: dyld's own message when it refused to load the image.
    private static func message(for error: any Error) -> String {
        if let dyldOpenError = error as? DyldOpenError, let message = dyldOpenError.message {
            return message
        }
        return error.localizedDescription
    }
}
