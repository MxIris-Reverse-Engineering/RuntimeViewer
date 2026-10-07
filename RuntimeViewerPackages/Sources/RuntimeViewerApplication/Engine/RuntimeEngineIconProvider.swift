#if os(macOS)
import AppKit
import Combine
import Dependencies
import DependenciesMacros
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerEngineManagement
import RuntimeViewerArchitectures

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

    /// Icons handed over by whoever created the engine, for engines this type
    /// cannot resolve on its own. See ``record(_:for:)``.
    private var recordedEngineIcons: [String: NSImage] = [:]

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
                pruneRecordedEngineIcons(attachedEngines: engines, bonjourEngines: runtimeEngineManager.bonjourRuntimeEngines)
            }
            .store(in: &cancellables)

        runtimeEngineManager.$bonjourRuntimeEngines
            .sink { [weak self] engines in
                guard let self else { return }
                pruneRecordedEngineIcons(attachedEngines: runtimeEngineManager.attachedRuntimeEngines, bonjourEngines: engines)
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
        recordedEngineIcons[engine.engineID]
            ?? attachedEngineIcons[engine.engineID]
            ?? mirroredEngineIcons[engine.engineID]
    }

    /// Keeps `icon` as this engine's, until the engine goes.
    ///
    /// For an engine whose icon nothing here can look up: a process on another
    /// device has no `NSRunningApplication` and no descriptor, and the bytes
    /// its icon comes from are a file in a bundle on that device. The attach
    /// flow is where that is known — it fetched the icon to draw the row the
    /// user clicked — so it pushes the answer in rather than this type going
    /// and asking again.
    ///
    /// A daemon is recorded too, with whatever generic icon the picker showed
    /// for it. That is deliberate: it is the difference between an engine the
    /// caller has no icon for and one it knows has none, and only the second
    /// should stop the engine list falling back to the icon of the *device*.
    public func record(_ icon: NSImage, for engine: RuntimeEngine) {
        guard recordedEngineIcons[engine.engineID] !== icon else { return }
        recordedEngineIcons[engine.engineID] = icon
        recordedIconsChangedRelay.accept(())
    }

    /// Fires when ``record(_:for:)`` gives an engine an icon it did not have.
    ///
    /// Every other icon here is in place before anything draws: both sinks above
    /// run from the manager's `willSet`, so they are done by the time it
    /// republishes its sections. A recorded one cannot be — the attach flow only
    /// learns which engine the icon belongs to once that engine has reported in,
    /// which is well after the engine list was published and the menu built from
    /// it. Without this signal the row keeps the *device's* glyph until
    /// something else happens to rebuild the menu, and selecting the row is one
    /// of those things: the icon appeared the moment you clicked it.
    public var recordedIconsChanged: Driver<Void> {
        recordedIconsChangedRelay.asDriver(onErrorDriveWith: .empty())
    }

    private let recordedIconsChangedRelay = PublishRelay<Void>()

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

    /// Drops recorded icons whose engine is gone.
    ///
    /// Against both lists, because an injected process reports back either way:
    /// a current device payload dials the host and lands among the attached
    /// engines, while a simulator payload — and a device app built before the
    /// rendezvous existed — advertises itself and lands among the Bonjour ones.
    /// Pruning against one list alone would drop the other's icon on the next
    /// change to it.
    private func pruneRecordedEngineIcons(attachedEngines: [RuntimeEngine], bonjourEngines: [RuntimeEngine]) {
        guard !recordedEngineIcons.isEmpty else { return }
        let currentEngineIDs = Set(attachedEngines.map(\.engineID)).union(bonjourEngines.map(\.engineID))
        recordedEngineIcons = recordedEngineIcons.filter { currentEngineIDs.contains($0.key) }
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
