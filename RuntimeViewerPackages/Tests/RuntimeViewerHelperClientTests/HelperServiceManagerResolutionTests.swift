#if os(macOS)

import Foundation
import Testing
import Dependencies
@testable import RuntimeViewerHelperClient

/// `\.helperServiceManager` builds its live value behind `MainActor.assumeIsolated`, so the
/// first resolution of the key in a process has to happen on the main actor; anywhere else it
/// aborts. The two clients that wrap the manager are called from non-isolated code —
/// `RuntimeEngineManager`'s reconnect pass calls `fetchAllInjectedEndpoints()` from a task on
/// the cooperative pool — and used to resolve the key right there. That held only while
/// something else happened to resolve it on the main actor first, and the app aborted at launch
/// once `RuntimeEngineManager.init` stopped doing that for an app whose Mac Catalyst engine runs
/// in the embedded service.
///
/// Each case runs in a process of its own (an exit test): only a fresh process can be the first
/// to resolve the key, and an abort can only be observed from outside. Past resolving the key,
/// each call goes on to talk to whatever helper daemon this machine has, or fails to; none of
/// that is under test, so a watchdog ends the process successfully if the call is still waiting
/// after a few seconds.
@Suite("Helper service manager resolution")
struct HelperServiceManagerResolutionTests {
    @Test("The injection client resolves the helper service manager on the main actor")
    func injectionClientResolvesOnMainActor() async {
        await #expect(processExitsWith: .success) {
            endSuccessfullyIfStillWaiting()
            await withDependencies {
                $0.context = .live
            } operation: {
                @Dependency(\.runtimeInjectClient) var runtimeInjectClient
                // Off the main actor and first in the process, the way the reconnect pass
                // calls it at launch.
                _ = try? await runtimeInjectClient.fetchAllInjectedEndpoints()
            }
        }
    }

    @Test("The Catalyst helper client resolves the helper service manager on the main actor")
    func helperClientResolvesOnMainActor() async {
        await #expect(processExitsWith: .success) {
            endSuccessfullyIfStillWaiting()
            await withDependencies {
                $0.context = .live
            } operation: {
                @Dependency(\.runtimeHelperClient) var runtimeHelperClient
                await runtimeHelperClient.reconnect()
            }
        }
    }
}

/// Ends an exit test's process successfully after a few seconds. What a case checks is decided
/// within microseconds — resolving the key either aborts the process at once or it does not —
/// and the daemon round trip that follows may take as long as it likes.
private func endSuccessfullyIfStillWaiting() {
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        exit(EXIT_SUCCESS)
    }
}

#endif
