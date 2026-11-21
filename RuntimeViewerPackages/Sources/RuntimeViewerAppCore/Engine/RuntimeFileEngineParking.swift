import Combine
import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerEngineManagement
import Dependencies
import DependenciesMacros

/// Lets a file engine's file go once no document has been on the engine for a
/// while, giving back the memory of the parsed file
/// (``RuntimeFileOpener/letGoOfFile(readBy:)``).
///
/// On the Mac the engine stays in the runtime source picker's list,
/// suspended; whoever brings a document back to it — that list, opening the
/// file again — resumes it first, in a new instance of the file service that
/// reads the file anew. Where files are read in this process (iOS, visionOS)
/// the engine cannot be suspended and is taken off the list instead; opening
/// the file again reads it anew. A document that comes back within the grace
/// period finds the engine as it was.
@Loggable
@MainActor
public final class RuntimeFileEngineParking {
    fileprivate static let shared = RuntimeFileEngineParking()

    /// How long a file engine nobody is on keeps its file: long enough
    /// that closing a window and opening the file again, or switching away and
    /// back, does not read the file again.
    static let defaultGracePeriod: Duration = .seconds(30)

    @Dependency(\.runtimeEngineBackgroundWorkRegistry) private var runtimeEngineBackgroundWorkRegistry

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    @Dependency(\.runtimeFileOpener) private var runtimeFileOpener

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
            guard runtimeEngineManager.file(of: engine) != nil else { return }
            let engineIdentifier = ObjectIdentifier(engine)
            pendingSuspensions[engineIdentifier]?.cancel()
            pendingSuspensions[engineIdentifier] = Task { [weak self, gracePeriod] in
                try? await Task.sleep(for: gracePeriod)
                guard !Task.isCancelled, let self else { return }
                pendingSuspensions[engineIdentifier] = nil
                #log(.info, "No document has been on \(engine.source.description, privacy: .public) for \(String(describing: gracePeriod), privacy: .public); letting its file go")
                await runtimeFileOpener.letGoOfFile(readBy: engine)
            }
        }
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeFileEngineParking.shared })
    public var runtimeFileEngineParking: RuntimeFileEngineParking
}
