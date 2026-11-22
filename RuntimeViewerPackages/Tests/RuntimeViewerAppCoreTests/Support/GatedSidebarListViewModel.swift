import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
@testable import RuntimeViewerAppCore

/// The sidebar's object list of an image, loading it for as long as the test lets it: it takes the
/// image for loaded, and every build waits until `finishBuild(with:)` or `failBuild()` ends it. The
/// list on screen while an image is being indexed, for what waits for that list.
@MainActor
final class GatedSidebarListViewModel: SidebarRuntimeObjectListViewModel {
    private enum InjectedBuildFailure: Error {
        case injected
    }

    private var pendingBuilds: [AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation] = []

    /// Whether a build waits for the test.
    var isBuilding: Bool {
        !pendingBuilds.isEmpty
    }

    override func isImageLoaded() async throws -> Bool {
        true
    }

    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { continuation in
            pendingBuilds.append(continuation)
        }
    }

    /// Ends every waiting build with `objects`: the list shows them.
    func finishBuild(with objects: [RuntimeObject]) {
        let builds = pendingBuilds
        pendingBuilds = []
        for build in builds {
            build.yield(.completed(objects))
            build.finish()
        }
    }

    /// Ends every waiting build with an error: the list shows that it could not load the image.
    func failBuild() {
        let builds = pendingBuilds
        pendingBuilds = []
        for build in builds {
            build.finish(throwing: InjectedBuildFailure.injected)
        }
    }
}
