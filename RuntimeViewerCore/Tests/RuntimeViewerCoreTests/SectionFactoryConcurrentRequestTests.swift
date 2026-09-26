import Testing
import Foundation
@testable import RuntimeViewerCore

/// Two requests for the same image that overlap in time share one build.
///
/// The background indexer and the sidebar both ask a section factory for an
/// image, and nothing keeps them from asking for the same one at once: opening
/// an image right after launch, while an "always index" batch is building it,
/// is the ordinary case. Building it a second time costs the whole build again
/// and slows every other build in the process with it (the proposal
/// draft-background-indexing-yields-to-foreground measured it). Evolution 0002
/// (background indexing) already required the factories to serialize per path.
///
/// Foundation builds for long enough that two `async let` requests always
/// overlap, so a factory that builds twice hands back two different sections.
@Suite("Section factories build each image once")
struct SectionFactoryConcurrentRequestTests {
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"

    @Test("ObjC: overlapping requests for one image get the same section")
    func objcOverlappingRequestsShareOneSection() async throws {
        let factory = RuntimeObjCSectionFactory()

        async let firstRequest = factory.section(for: Self.foundationPath)
        async let secondRequest = factory.section(for: Self.foundationPath)
        let (firstResult, secondResult) = try await (firstRequest, secondRequest)

        #expect(firstResult.section === secondResult.section)
    }

    @Test("Swift: overlapping requests for one image get the same section")
    func swiftOverlappingRequestsShareOneSection() async throws {
        let factory = RuntimeSwiftSectionFactory()

        async let firstRequest = factory.section(for: Self.foundationPath)
        async let secondRequest = factory.section(for: Self.foundationPath)
        let (firstResult, secondResult) = try await (firstRequest, secondRequest)

        #expect(firstResult.section === secondResult.section)
    }

    @Test("ObjC: a request that joins a build under way still receives its progress")
    func objcJoiningRequestReceivesProgress() async throws {
        let factory = RuntimeObjCSectionFactory()
        let progressRecorder = ProgressRecorder()

        async let backgroundRequest = factory.section(for: Self.foundationPath)
        async let foregroundRequest = progressRecorder.recording { continuation in
            try await factory.section(for: Self.foundationPath, progressContinuation: continuation)
        }
        _ = try await (backgroundRequest, foregroundRequest)

        #expect(await progressRecorder.progressEventCount > 0)
    }

    @Test("Swift: a request that joins a build under way still receives its progress")
    func swiftJoiningRequestReceivesProgress() async throws {
        let factory = RuntimeSwiftSectionFactory()
        let progressRecorder = ProgressRecorder()

        async let backgroundRequest = factory.section(for: Self.foundationPath)
        async let foregroundRequest = progressRecorder.recording { continuation in
            try await factory.section(for: Self.foundationPath, progressContinuation: continuation)
        }
        _ = try await (backgroundRequest, foregroundRequest)

        #expect(await progressRecorder.progressEventCount > 0)
    }
}

/// Counts the progress events a request receives through its continuation,
/// draining them the way `RuntimeEngine.pumpingIndexingProgress` does.
private actor ProgressRecorder {
    private(set) var progressEventCount = 0

    func recording<Result: Sendable>(
        _ body: @Sendable (LoadingEventContinuation) async throws -> Result
    ) async throws -> Result {
        let (stream, continuation) = AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error>.makeStream()
        let pump = Task {
            for try await event in stream {
                if case .progress = event {
                    self.recordProgressEvent()
                }
            }
        }
        do {
            let result = try await body(continuation)
            continuation.finish()
            _ = await pump.result
            return result
        } catch {
            continuation.finish()
            _ = await pump.result
            throw error
        }
    }

    private func recordProgressEvent() {
        progressEventCount += 1
    }
}
