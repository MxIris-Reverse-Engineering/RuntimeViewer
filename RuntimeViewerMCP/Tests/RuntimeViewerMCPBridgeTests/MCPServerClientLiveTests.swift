import Foundation
import Observation
import Dependencies
import Testing
import RuntimeViewerAppCore
@testable import RuntimeViewerMCPBridge

/// The MCP status popover, in RuntimeViewerAppCore, reaches the server only through
/// `MCPServerClient`, whose live value this module supplies. `CrossLayerDependencyTests` in
/// RuntimeViewerPackages cannot link this package, so the live value is checked here.
///
/// The `.preview` dependency context keeps the `\.settings` accesses in `stop()` and `deinit` off
/// the unimplemented-dependency test trap, as in `MCPServiceBindFailureTests`.
@Suite("MCPServerClient live value", .serialized)
@MainActor
struct MCPServerClientLiveTests {
    @Test("the key has a live value: the app's own service")
    func liveValueExists() {
        // Building the value touches no service: its closures look the service up when called.
        _ = MCPServerClientKey.liveValue
    }

    @Test("the client reads the service's state, and a change to it is observable")
    func liveClientFollowsServiceState() async throws {
        try await withDependencies {
            $0.context = .preview
        } operation: {
            let portFilePath = scratchPortFilePath()
            defer { try? FileManager.default.removeItem(atPath: portFilePath) }
            let service = MCPService(portFilePath: portFilePath)
            let client = MCPServerClient.driving { service }
            #expect(client.state() == .stopped)

            var changeCount = 0
            withObservationTracking {
                _ = client.state()
            } onChange: {
                MainActor.assumeIsolated { changeCount += 1 }
            }

            await service.startTransport(on: 0, for: MockMCPBridgeDocumentProvider())

            guard case .running(let boundPort) = client.state() else {
                Issue.record("the service never reached .running: \(client.state())")
                return
            }
            #expect(boundPort != 0)
            #expect(changeCount == 1)

            client.stop()
            #expect(client.state() != .running(port: boundPort))
        }
    }

    @Test("resuming a service that was never started does nothing")
    func resumeWithoutDocumentProviderDoesNothing() {
        withDependencies {
            $0.context = .preview
        } operation: {
            let portFilePath = scratchPortFilePath()
            defer { try? FileManager.default.removeItem(atPath: portFilePath) }
            let service = MCPService(portFilePath: portFilePath)
            let client = MCPServerClient.driving { service }

            client.start()

            #expect(client.state() == .stopped)
            #expect(service.transport == nil)
            #expect(!FileManager.default.fileExists(atPath: portFilePath))
        }
    }

    private func scratchPortFilePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-server-client-tests-\(UUID().uuidString)")
            .path
    }
}
