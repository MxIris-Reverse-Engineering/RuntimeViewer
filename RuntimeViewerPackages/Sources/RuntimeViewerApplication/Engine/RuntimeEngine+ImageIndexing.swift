import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

extension RuntimeEngine {
    /// Indexes the image at `imagePath` the way the sidebar opens one — loads
    /// it first when the engine's process has not, as the sidebar's Load does
    /// — unless it is indexed already; a build of it under way is joined.
    /// For an object a Find hit reached through a corpus read from derived
    /// data (proposal `draft-derived-data`): the corpus is searchable before
    /// the image has sections, and the image need not even be loaded in the
    /// serving process, which reads a corpus without loading anything.
    nonisolated func indexImageIfNeeded(at imagePath: String) async throws {
        guard try await !isImageIndexed(path: imagePath) else { return }
        if try await isImageLoaded(path: imagePath) {
            for try await _ in await objectsWithProgress(in: imagePath) {}
        } else {
            try await loadImage(at: imagePath)
        }
    }

    /// Emits once when this engine reports `imagePath` indexed, and completes
    /// without emitting when the image is indexed already — the moment a pane
    /// showing an object of an image without sections has more to show. Such
    /// an object reaches a pane through a Find hit whose corpus came from
    /// derived data (proposal `draft-derived-data`).
    ///
    /// The engine's reports are followed before the question is asked, so an
    /// image indexed in between is not missed. A question that fails is taken
    /// for "not indexed", which leaves the pane to wait for a report.
    nonisolated func imageIndexedLater(_ imagePath: String) -> Observable<Void> {
        enum Report {
            case indexed
            case alreadyIndexed
            case notIndexed
        }
        let canonicalImagePath = canonicalImagePath(imagePath)
        let indexedReports = imageDidIndexPublisher.asObservable()
            .filter { [weak self] reportedImagePath in
                self?.canonicalImagePath(reportedImagePath) == canonicalImagePath
            }
            .map { _ in Report.indexed }
        let answer = Observable<Report>.async { [weak self] in
            guard let self else { return .notIndexed }
            return try await isImageIndexed(path: imagePath) ? .alreadyIndexed : .notIndexed
        }
        .catchAndReturn(.notIndexed)
        return Observable.merge(indexedReports, answer.filter { $0 == .alreadyIndexed })
            .take(1)
            .filter { $0 == .indexed }
            .map { _ in () }
    }
}
