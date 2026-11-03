#if os(macOS)
import Combine
import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerEngineManagement
import Dependencies
import DependenciesMacros

/// Lets an offline engine's process go once no document has been on the engine
/// for a while, giving back the memory of the parsed file.
///
/// The engine stays in the engine menu, suspended; whoever brings a document
/// back to it — the engine menu, opening the file again — resumes it first, in
/// a new instance of the offline service that reads the file anew. A document
/// that comes back within the grace period finds the engine as it was.
@Loggable
@MainActor
public final class RuntimeOfflineEngineParking {
    fileprivate static let shared = RuntimeOfflineEngineParking()

    /// How long an offline engine nobody is on keeps its process: long enough
    /// that closing a window and opening the file again, or switching away and
    /// back, does not read the file again.
    static let defaultGracePeriod: Duration = .seconds(30)

    @Dependency(\.runtimeEngineBackgroundWorkRegistry) private var runtimeEngineBackgroundWorkRegistry

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    /// Test seam.
    var gracePeriod: Duration = defaultGracePeriod

    /// The suspension waiting out the grace period, by engine.
    private var pendingSuspensions: [ObjectIdentifier: Task<Void, Never>] = [:]

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

    /// Whether `engine`'s suspension is waiting out the grace period. Test seam.
    func isSuspensionPending(for engine: RuntimeEngine) -> Bool {
        pendingSuspensions[ObjectIdentifier(engine)] != nil
    }

    private func handle(_ change: RuntimeEngineOccupancyChange) {
        switch change {
        case .occupied(let engine):
            pendingSuspensions.removeValue(forKey: ObjectIdentifier(engine))?.cancel()
        case .vacated(let engine):
            guard runtimeEngineManager.offlineFile(of: engine) != nil else { return }
            let engineIdentifier = ObjectIdentifier(engine)
            pendingSuspensions[engineIdentifier]?.cancel()
            pendingSuspensions[engineIdentifier] = Task { [weak self, gracePeriod] in
                try? await Task.sleep(for: gracePeriod)
                guard !Task.isCancelled, let self else { return }
                pendingSuspensions[engineIdentifier] = nil
                #log(.info, "No document has been on \(engine.source.description, privacy: .public) for \(String(describing: gracePeriod), privacy: .public); letting its process go")
                await runtimeEngineManager.suspendOfflineEngine(engine)
            }
        }
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeOfflineEngineParking.shared })
    public var runtimeOfflineEngineParking: RuntimeOfflineEngineParking
}
#endif
