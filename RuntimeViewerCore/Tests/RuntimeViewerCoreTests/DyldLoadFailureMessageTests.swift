#if canImport(Network) && os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// dyld's own words for an image it refused to load — `Library not loaded`,
/// `Referenced from`, every path it tried — are all the user learns about why
/// a load failed, so they have to reach the caller over every way an engine
/// forwards a request. A failure crosses XPC as its `localizedDescription` and
/// a socket as its `String(describing:)`; while `DyldOpenError` provided
/// neither, the app's "My Mac", which forwards to the local XPC service,
/// showed "The operation couldn't be completed. (RuntimeViewerCore.DyldOpenError
/// error 1.)" and nothing of dyld's message.
@Suite("dyld load failure message", .serialized)
struct DyldLoadFailureMessageTests {
    private static let missingImagePath = "/nonexistent/RuntimeViewerTests/Missing.framework/Versions/A/Missing"

    @Test("An engine in process fails a load with dyld's message")
    func inProcessEngineReportsDyldMessage() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "dyld-load-failure-message.in-process")
        try await engine.connect()
        defer { Task { await engine.stop() } }

        let error = await #expect(throws: (any Error).self) {
            try await engine.loadImage(at: Self.missingImagePath)
        }

        Self.expectDyldMessage(in: error)
    }

    @Test("A forwarded load fails with dyld's message", arguments: RemoteEnginePair.Transport.allCases)
    func forwardedLoadReportsDyldMessage(transport: RemoteEnginePair.Transport) async throws {
        let label = "dyld-load-failure-message.\(transport)"
        let serving = try await RemoteEnginePair.makeServingEngine(label: label, loading: [])
        let pair = try await RemoteEnginePair.make(transport, label: label, serving: serving)
        defer {
            Task {
                await pair.stop()
                await serving.stop()
            }
        }

        let error = await #expect(throws: (any Error).self) {
            try await pair.client.loadImage(at: Self.missingImagePath)
        }

        Self.expectDyldMessage(in: error)
    }

    /// dyld words a refused `dlopen` as `dlopen(<path>, <mode>): ` followed by
    /// what it tried; a path that does not exist is "no such file" at every
    /// place it looked.
    private static func expectDyldMessage(in error: (any Error)?, sourceLocation: SourceLocation = #_sourceLocation) {
        let description = error?.localizedDescription ?? ""
        #expect(description.hasPrefix("dlopen(\(missingImagePath), "), "not dyld's message: \(description)", sourceLocation: sourceLocation)
        #expect(description.contains("no such file"), "dyld's reason is missing: \(description)", sourceLocation: sourceLocation)
    }
}

#endif
