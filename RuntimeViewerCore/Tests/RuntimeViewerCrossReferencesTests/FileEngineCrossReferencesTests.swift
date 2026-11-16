import Testing
import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerCrossReferences

/// A file's images are never mapped into a process, so there is no
/// code to scan: an engine reading a file answers every cross-reference
/// command the way a peer without the commands does, which the app already
/// shows as a source that cannot serve cross references.
@Suite("Cross references on an engine reading a file")
struct FileEngineCrossReferencesTests {
    @Test("An engine reading a file answers cross-reference commands as a peer without them, without asking")
    func fileEngineAnswersUnknownCommand() async throws {
        let file = try RuntimeFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        let engine = try RuntimeEngine(reading: file, engineID: "file-cross-references-test")
        try await engine.connect()
        defer { Task { await engine.stop() } }

        do {
            _ = try await engine.preparedCrossReferenceByteCount()
            Issue.record("an engine reading a file answered a cross-reference command")
        } catch let error as RuntimeNetworkRequestError {
            #expect(error.isUnknownCommand, "the engine answered \(error.message)")
        }
    }
}
