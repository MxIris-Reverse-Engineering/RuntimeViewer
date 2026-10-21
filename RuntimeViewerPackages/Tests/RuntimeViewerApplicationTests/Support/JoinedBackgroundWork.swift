import Testing
@testable import RuntimeViewerApplication

/// The coordinators of the background work a document joined with
/// `startBackgroundWork()` — how every test reaches them. Asked of a document
/// that has not started, they fail the test they are asked in, not the whole
/// run: such a document hands out closed coordinators, which do nothing a test
/// could wait for.
extension DocumentState {
    func joinedIndexingCoordinator(sourceLocation: SourceLocation = #_sourceLocation) throws -> RuntimeBackgroundIndexingCoordinator {
        try joinedBackgroundWork(sourceLocation: sourceLocation).indexingCoordinator
    }

    func joinedCorpusCoordinator(sourceLocation: SourceLocation = #_sourceLocation) throws -> FindCorpusCoordinator {
        try joinedBackgroundWork(sourceLocation: sourceLocation).corpusCoordinator
    }

    func joinedCrossReferencePreparationCoordinator(sourceLocation: SourceLocation = #_sourceLocation) throws -> CrossReferencePreparationCoordinator {
        try joinedBackgroundWork(sourceLocation: sourceLocation).crossReferencePreparationCoordinator
    }

    private func joinedBackgroundWork(sourceLocation: SourceLocation) throws -> RuntimeEngineBackgroundWork {
        try #require(backgroundWork, "the document has not started its background work", sourceLocation: sourceLocation)
    }
}
