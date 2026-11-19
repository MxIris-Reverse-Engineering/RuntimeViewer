#if os(macOS)
import Combine
import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerEngineManagement
import Dependencies
import DependenciesMacros

/// Ends a framework instance as soon as no document is on its engine — its
/// window closed, or moved to another source — so the frameworks loaded into
/// it are unloaded with its process.
///
/// No grace period, unlike `RuntimeFileEngineParking`: a file engine's process
/// can be started again by reading the file again, but starting a framework
/// instance again would run the frameworks' constructors again, which must
/// never happen behind the user's back. The same engine starting over (its
/// instance came back after a crash) keeps its document, so nothing here hears it.
@Loggable
@MainActor
public final class RuntimeFrameworkInstanceRetirement {
    fileprivate static let shared = RuntimeFrameworkInstanceRetirement()

    @Dependency(\.runtimeEngineBackgroundWorkRegistry) private var runtimeEngineBackgroundWorkRegistry

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    private var occupancySubscription: AnyCancellable?

    init() {}

    /// Starts watching documents come and go. Calling it again does nothing.
    public func start() {
        guard occupancySubscription == nil else { return }
        occupancySubscription = runtimeEngineBackgroundWorkRegistry.occupancyChanges.sink { [weak self] change in
            guard let self else { return }
            handle(change)
        }
    }

    private func handle(_ change: RuntimeEngineOccupancyChange) {
        guard case .vacated(let engine) = change,
              runtimeEngineManager.frameworkInstanceEngines.contains(where: { $0 === engine })
        else { return }
        #log(.info, "No document is on \(engine.source.description, privacy: .public) any more; ending its instance")
        runtimeEngineManager.terminateFrameworkInstance(engine)
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeFrameworkInstanceRetirement.shared })
    public var runtimeFrameworkInstanceRetirement: RuntimeFrameworkInstanceRetirement
}
#endif
