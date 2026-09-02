import Dependencies
import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// Runs `operation` with the live dependency context.
///
/// swift-dependencies defaults to `.test` inside a test target, which
/// makes every `@Dependency` without an explicit `testValue` trap. View
/// models under test resolve `\.settings` / `\.appDefaults` eagerly, so
/// they must be constructed here.
///
/// `appDefaults` is the one key that must not go live: its live value is
/// file-backed under a path the running app shares, so it is pinned to an
/// isolated instance (see `ViewModelTestEnvironment`).
func withLiveDependencyContext<Result>(_ operation: () throws -> Result) rethrows -> Result {
    try withDependencies {
        $0.context = .live
        $0.appDefaults = AppDefaults.isolated()
    } operation: {
        try operation()
    }
}

/// Polls `condition` until it holds or `timeout` elapses.
///
/// Returns whether the condition was met, so the call site can `#expect`
/// on it with a message rather than failing on a bare timeout.
func pollUntil(
    timeout: Duration,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return false
}

/// Borrows a leaf image node the shared local engine really reports as
/// loaded, so `reloadData()` gets past its `.notLoaded` early return and a
/// seeded subclass's `buildRuntimeObjects()` is the thing under test.
///
/// `RuntimeImageNode.parent` is weak and `absolutePath` derives from it
/// lazily, so the path has to be materialized while the root still owns the
/// ancestor chain — hand back a bare leaf and the chain deallocates behind
/// it, collapsing `path` to "/" and pinning the view model at `.notLoaded`.
func makeLoadedImageNode() async throws -> RuntimeImageNode {
    let localRuntimeEngine = RuntimeEngine.local
    var imageList: [String] = []
    let engineReady = try await pollUntil(timeout: .seconds(15)) {
        imageList = await localRuntimeEngine.imageList
        return !imageList.isEmpty
    }
    #expect(engineReady, "local engine never published an image list")
    let imagePath = try #require(imageList.first { $0.hasSuffix("/Foundation") } ?? imageList.first)

    let rootImageNode = RuntimeImageNode.rootNode(for: [imagePath], name: "Root")
    var leafImageNode = rootImageNode
    while let firstChild = leafImageNode.children.first {
        leafImageNode = firstChild
    }
    withExtendedLifetime(rootImageNode) {
        _ = leafImageNode.absolutePath
    }
    return leafImageNode
}
