import Foundation
import Dependencies
import Testing
@testable import RuntimeViewerMCPBridge

/// Regression tests for proposal 0006: a bind failure must tear the
/// transport down (freeing its eagerly-created NIO event-loop group),
/// report `.stopped` truthfully, and never touch the port file — and a
/// failed-bind instance's `stop()` must not delete the port file the
/// winning instance wrote.
///
/// The suite drives `startTransport(on:for:)` directly (the internal seam
/// below `start(for:)`) so no settings observation is installed. The
/// `.preview` dependency context keeps the `\.settings` accesses in
/// `stop()` / `deinit` off the unimplemented-dependency test trap.
@Suite("MCPServiceBindFailure", .serialized)
@MainActor
struct MCPServiceBindFailureTests {
    @Test("bind failure tears down the transport, reports .stopped, and leaves the winner's port file intact")
    func bindFailureTeardown() async throws {
        try await withDependencies {
            $0.context = .preview
        } operation: {
            let portFilePath = scratchPortFilePath()
            defer { try? FileManager.default.removeItem(atPath: portFilePath) }

            // Winner: ephemeral port, must reach .running and write the file.
            let winningService = MCPService(portFilePath: portFilePath)
            await winningService.startTransport(on: 0, for: MockMCPBridgeDocumentProvider())

            guard case .running(let boundPort) = winningService.serverState else {
                Issue.record("winning instance never reached .running: \(winningService.serverState)")
                return
            }
            #expect(boundPort != 0)
            let writtenPort = try String(contentsOfFile: portFilePath, encoding: .utf8)
            #expect(writtenPort == "\(boundPort)")

            // Loser: same fixed port, must fail the bind and clean up fully.
            let losingService = MCPService(portFilePath: portFilePath)
            await losingService.startTransport(on: boundPort, for: MockMCPBridgeDocumentProvider())

            #expect(losingService.serverState == .stopped)
            #expect(losingService.transport == nil)
            // The winner's port file survives the loser's failed start...
            #expect(try String(contentsOfFile: portFilePath, encoding: .utf8) == "\(boundPort)")

            // ...and survives the loser's stop() too: it never owned the file.
            losingService.stop()
            #expect(FileManager.default.fileExists(atPath: portFilePath))
            #expect(try String(contentsOfFile: portFilePath, encoding: .utf8) == "\(boundPort)")

            // The winner's stop() does remove its own file.
            winningService.stop()
            #expect(!FileManager.default.fileExists(atPath: portFilePath))
        }
    }

    @Test("a successful ephemeral bind resolves port 0 to a real port")
    func ephemeralBindResolvesPort() async throws {
        try await withDependencies {
            $0.context = .preview
        } operation: {
            let portFilePath = scratchPortFilePath()
            defer { try? FileManager.default.removeItem(atPath: portFilePath) }

            let service = MCPService(portFilePath: portFilePath)
            await service.startTransport(on: 0, for: MockMCPBridgeDocumentProvider())

            #expect(service.serverState.isRunning)
            #expect(service.transport != nil)
            let writtenPort = try String(contentsOfFile: portFilePath, encoding: .utf8)
            #expect(UInt16(writtenPort) != nil)
            #expect(UInt16(writtenPort) != 0)

            service.stop()
            #expect(!FileManager.default.fileExists(atPath: portFilePath))
        }
    }

    private func scratchPortFilePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-bind-failure-tests-\(UUID().uuidString)")
            .path
    }
}
