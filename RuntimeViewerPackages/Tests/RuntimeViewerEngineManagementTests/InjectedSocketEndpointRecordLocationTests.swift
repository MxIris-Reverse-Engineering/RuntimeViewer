import Testing
import Foundation
@testable import RuntimeViewerEngineManagement

/// The manager remembers the sandboxed apps it injected over a local socket,
/// to listen for them again at its next launch, and forgets every one it could
/// not reconnect. A Debug app and the released one used to share that file:
/// each listened for the processes the other had injected — taking over those
/// it reached first — and dropped the records of those it could not, which
/// were the other app's. The codebase audit's CA.16.
@Suite("Injected socket endpoint records")
@MainActor
struct InjectedSocketEndpointRecordLocationTests {
    @Test("A Debug build keeps its injected socket endpoint records apart from the released app's")
    func recordsLiveInTheBuildsOwnApplicationDirectory() {
        let directory = RuntimeEngineManager.injectedSocketEndpointsFileURL.deletingLastPathComponent()
        #if DEBUG
        #expect(directory.lastPathComponent == "RuntimeViewer-Debug")
        #else
        #expect(directory.lastPathComponent == "RuntimeViewer")
        #endif
    }
}
