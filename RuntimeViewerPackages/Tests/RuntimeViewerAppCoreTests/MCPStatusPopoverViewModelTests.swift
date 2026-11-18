#if os(macOS)

import Foundation
import Observation
import Testing
import Dependencies
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The MCP status popover drives the server through `mcpServerClient` and copies through
/// `pasteboardClient`, so a test drives a server of its own and reads what was copied.
@Suite("MCP status popover")
@MainActor
struct MCPStatusPopoverViewModelTests {
    /// A server whose state is observable, as `MCPService`'s is, and that counts what it was asked.
    @Observable
    @MainActor
    final class TestServer {
        var state: MCPServerState
        var startCount = 0
        var stopCount = 0

        init(state: MCPServerState) {
            self.state = state
        }

        var client: MCPServerClient {
            MCPServerClient(
                state: { self.state },
                start: { self.startCount += 1 },
                stop: { self.stopCount += 1 }
            )
        }
    }

    private struct Popover {
        let viewModel: MCPStatusPopoverViewModel<AppRoute>
        let output: MCPStatusPopoverViewModel<AppRoute>.Output
    }

    private let environment = ViewModelTestEnvironment()
    private let router = MockRouter<AppRoute>()
    private let appRouter = MockRouter<AppRoute>()
    private let actionButtonClickRelay = PublishRelay<Void>()
    private let copyPortClickRelay = PublishRelay<Void>()
    private let copyConfigRelay = PublishRelay<MCPConfigType>()

    private func makePopover(on server: TestServer) -> Popover {
        withDependencies {
            $0.mcpServerClient = server.client
            $0.appRouter = appRouter
        } operation: {
            environment.make {
                let viewModel = MCPStatusPopoverViewModel(documentState: environment.documentState, router: router)
                let output = viewModel.transform(.init(
                    actionButtonClick: actionButtonClickRelay.asSignal(),
                    copyPortClick: copyPortClickRelay.asSignal(),
                    copyConfig: copyConfigRelay.asSignal()
                ))
                return Popover(viewModel: viewModel, output: output)
            }
        }
    }

    @Test("the action button opens Settings while MCP is turned off")
    func actionButtonOpensSettingsWhenDisabled() {
        let server = TestServer(state: .disabled)
        let popover = makePopover(on: server)
        defer { withExtendedLifetime(popover) {} }

        actionButtonClickRelay.accept(())

        #expect(appRouter.triggeredRoutes.count == 1)
        #expect(server.startCount == 0)
        #expect(server.stopCount == 0)
    }

    @Test("the action button starts a stopped server")
    func actionButtonStartsWhenStopped() {
        let server = TestServer(state: .stopped)
        let popover = makePopover(on: server)
        defer { withExtendedLifetime(popover) {} }

        actionButtonClickRelay.accept(())

        #expect(server.startCount == 1)
        #expect(server.stopCount == 0)
        #expect(appRouter.triggeredRoutes.isEmpty)
    }

    @Test("the action button stops a running server")
    func actionButtonStopsWhenRunning() {
        let server = TestServer(state: .running(port: 4567))
        let popover = makePopover(on: server)
        defer { withExtendedLifetime(popover) {} }

        actionButtonClickRelay.accept(())

        #expect(server.stopCount == 1)
        #expect(server.startCount == 0)
    }

    @Test("Copy Port copies the running server's port through the pasteboard client")
    func copyPortCopiesThroughPasteboardClient() {
        let server = TestServer(state: .running(port: 4567))
        let popover = makePopover(on: server)
        defer { withExtendedLifetime(popover) {} }

        copyPortClickRelay.accept(())

        #expect(environment.pasteboard.copiedStrings == ["4567"])
    }

    @Test("copying a configuration copies the client's command for the running server's port")
    func copyConfigurationCopiesClientCommand() {
        let server = TestServer(state: .running(port: 4567))
        let popover = makePopover(on: server)
        defer { withExtendedLifetime(popover) {} }

        copyConfigRelay.accept(.claudeCode)
        copyConfigRelay.accept(.json)

        #expect(environment.pasteboard.copiedStrings == [
            MCPConfigType.claudeCode.configString(port: 4567),
            MCPConfigType.json.configString(port: 4567),
        ])
    }

    @Test("nothing is copied while the server is not running")
    func copyingNeedsARunningServer() {
        let server = TestServer(state: .stopped)
        let popover = makePopover(on: server)
        defer { withExtendedLifetime(popover) {} }

        copyPortClickRelay.accept(())
        copyConfigRelay.accept(.codex)

        #expect(environment.pasteboard.copiedStrings.isEmpty)
    }

    @Test("the popover follows the server's state, and two popovers follow it at once")
    func stateFollowsServerWithoutCallbackSlot() async throws {
        let server = TestServer(state: .stopped)
        let firstPopover = makePopover(on: server)
        let secondPopover = makePopover(on: server)
        defer { withExtendedLifetime((firstPopover, secondPopover)) {} }

        server.state = .running(port: 4567)

        let firstState = try await nextValue(from: firstPopover.output.state) { $0 == .running(port: 4567) }
        let secondState = try await nextValue(from: secondPopover.output.state) { $0 == .running(port: 4567) }
        #expect(firstState == .running(port: 4567))
        #expect(secondState == .running(port: 4567))
    }
}

#endif
