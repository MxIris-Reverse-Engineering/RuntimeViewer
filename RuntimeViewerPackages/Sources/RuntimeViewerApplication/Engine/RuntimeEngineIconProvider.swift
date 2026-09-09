#if os(macOS)
import AppKit
import Combine
import Dependencies
import DependenciesMacros
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerEngineManagement

/// Icons for the engines `RuntimeEngineManager` holds, resolved the moment an
/// engine appears and dropped when it goes.
///
/// A locally attached engine is looked up through Launch Services while its
/// process is alive; a mirrored engine carries icon bytes in its descriptor,
/// which the manager keeps as data and this type decodes. The manager itself
/// links no AppKit, which is why this lives one layer up.
@MainActor
public final class RuntimeEngineIconProvider {
    fileprivate static let shared = RuntimeEngineIconProvider()

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    private var attachedEngineIcons: [String: NSImage] = [:]

    /// Attached engines already looked up, icon or not. A daemon Launch
    /// Services knows nothing about yields no icon, and is not asked again
    /// every time the attached list changes.
    private var attachedEngineIDsResolved: Set<String> = []

    private var mirroredEngineIcons: [String: NSImage] = [:]

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // `@Published` emits from `willSet`, so each sink sees the incoming
        // collection before the manager's property changes: the same moment
        // the manager used to fill its own cache, and before it rebuilds
        // `runtimeEngineSections` for the UI to read.
        runtimeEngineManager.$attachedRuntimeEngines
            .sink { [weak self] engines in
                guard let self else { return }
                reconcileAttachedEngines(engines)
            }
            .store(in: &cancellables)

        runtimeEngineManager.$mirroredEngines
            .sink { [weak self] engines in
                guard let self else { return }
                reconcileMirroredEngines(Array(engines.values))
            }
            .store(in: &cancellables)
    }

    /// The icon resolved for `engine`, or `nil` when there is none — a daemon
    /// with no bundle, or a mirrored engine whose descriptor carried no bytes.
    public func cachedIcon(for engine: RuntimeEngine) -> NSImage? {
        attachedEngineIcons[engine.engineID] ?? mirroredEngineIcons[engine.engineID]
    }

    // MARK: - Reconcile

    private func reconcileAttachedEngines(_ engines: [RuntimeEngine]) {
        let currentEngineIDs = Set(engines.map(\.engineID))
        for engine in engines where !attachedEngineIDsResolved.contains(engine.engineID) {
            attachedEngineIDsResolved.insert(engine.engineID)
            guard let processIdentifier = Self.processIdentifier(of: engine) else { continue }
            let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
            if let icon = runningApplication?.icon {
                attachedEngineIcons[engine.engineID] = icon
            } else if let bundleURL = runningApplication?.bundleURL {
                attachedEngineIcons[engine.engineID] = NSWorkspace.shared.icon(forFile: bundleURL.path)
            }
        }
        attachedEngineIDsResolved.formIntersection(currentEngineIDs)
        attachedEngineIcons = attachedEngineIcons.filter { currentEngineIDs.contains($0.key) }
    }

    private func reconcileMirroredEngines(_ engines: [RuntimeEngine]) {
        let currentEngineIDs = Set(engines.map(\.engineID))
        for engine in engines where mirroredEngineIcons[engine.engineID] == nil {
            guard let iconData = runtimeEngineManager.remoteIconData(for: engine),
                  let icon = NSImage(data: iconData)
            else { continue }
            mirroredEngineIcons[engine.engineID] = icon
        }
        mirroredEngineIcons = mirroredEngineIcons.filter { currentEngineIDs.contains($0.key) }
    }

    /// The pid an attached engine was created for. The manager keys attached
    /// engines by the target's pid, so it is the source identifier.
    private static func processIdentifier(of engine: RuntimeEngine) -> pid_t? {
        switch engine.source {
        case .remote(_, let identifier, .client), .localSocket(_, let identifier, .client):
            return pid_t(identifier.rawValue)
        default:
            return nil
        }
    }
}

// MARK: - Dependencies

@MainActor
extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeEngineIconProvider.shared })
    public var runtimeEngineIconProvider: RuntimeEngineIconProvider
}
#endif
