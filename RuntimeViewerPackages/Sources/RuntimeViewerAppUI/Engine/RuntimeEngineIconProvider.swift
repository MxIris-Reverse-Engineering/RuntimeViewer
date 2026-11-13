#if os(macOS)
import AppKit
import Combine
import UniformTypeIdentifiers
import Dependencies
import DependenciesMacros
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerEngineManagement
import RuntimeViewerArchitectures
import RuntimeViewerUI
import RuntimeViewerAppCore

/// What stands for an engine wherever one is shown — the runtime source picker
/// and its list, the Report navigator's engine groups — and the icons of the
/// engines `RuntimeEngineManager` holds, resolved the moment an engine appears
/// and dropped when it goes.
///
/// A locally attached engine is looked up through Launch Services while its
/// process is alive; a mirrored engine carries icon bytes in its descriptor,
/// which the manager keeps as data and this type decodes. The manager itself
/// links no AppKit, which is why this lives one layer up.
@MainActor
public final class RuntimeEngineIconProvider {
    fileprivate static let shared = RuntimeEngineIconProvider(followsRuntimeEngineManager: true)

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

    /// - Parameter followsRuntimeEngineManager: Whether icons are looked up and
    ///   dropped as the manager's engines come and go. Only the process-wide
    ///   provider follows it. The dependency's test value does not, so a test
    ///   that shows an engine's icon starts no manager: each engine gets its
    ///   machine's glyph, its file's icon or the generic executable icon, and a
    ///   picture of its own only once one is recorded.
    fileprivate init(followsRuntimeEngineManager: Bool) {
        guard followsRuntimeEngineManager else { return }

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

    // MARK: - What Stands for an Engine

    /// The engine's icon in a list — the runtime source picker's, the Report
    /// navigator's engine groups: its machine's glyph squared, or a picture of
    /// its own.
    public func icon(for engine: RuntimeEngine) -> NSImage {
        switch iconKind(for: engine) {
        case .picture(let image):
            image
        case .machine:
            Self.machineIcon(for: engine)
        }
    }

    /// The engine's icon in the toolbar's runtime source picker: its machine's
    /// glyph as the symbol it is, which Xcode 27's style draws at its own size
    /// as Xcode draws a run destination's, or the picture a list shows.
    public func sourcePickerIcon(for engine: RuntimeEngine) -> RuntimeSourcePicker.Icon {
        switch iconKind(for: engine) {
        case .picture(let image):
            .image(image)
        case .machine:
            Self.machineSymbol(for: engine).map(RuntimeSourcePicker.Icon.symbol) ?? .image(Self.machineIcon(for: engine))
        }
    }

    /// What stands for an engine: the machine it runs on, or a picture of its own.
    private enum IconKind {
        case machine
        case picture(NSImage)
    }

    private func iconKind(for engine: RuntimeEngine) -> IconKind {
        switch engine.source {
        case .file(_, let url):
            // The file's own: an app's icon for an app, a framework's for a framework.
            return .picture(NSWorkspace.shared.icon(forFile: url.path))
        case .local:
            return .machine
        case .remote(_, let identifier, _) where identifier == .macCatalyst:
            return .machine
        default:
            if engine.hostInfo.hostID == RuntimeNetworkBonjour.localInstanceID {
                return .picture(cachedIcon(for: engine) ?? Self.genericExecutableIcon)
            } else {
                // The machine itself, for the engine that *is* the machine — the
                // RuntimeViewer running on it. A process injected on that device
                // is a different thing and gets an icon of its own, recorded by
                // the attach flow; falling back to the device here would list
                // every injected process under a picture of the phone.
                return cachedIcon(for: engine).map(IconKind.picture) ?? .machine
            }
        }
    }

    /// The glyph standing for the machine an engine runs on.
    ///
    /// Every machine row goes through this, the local Mac included, because one
    /// photorealistic row beside three flat ones is worse than either treatment
    /// on its own. `deviceIcon(forModelIdentifier:)` stays as the last resort:
    /// it substitutes a generic display, which is a fair showing of a machine
    /// whose model and platform both said nothing.
    private static func machineIcon(for engine: RuntimeEngine) -> NSImage {
        let metadata = engine.hostInfo.metadata
        return DeviceGlyph.image(
            forModelIdentifier: metadata.modelIdentifier,
            operatingSystemVersion: metadata.osVersion,
            isSimulator: metadata.isSimulator,
        ) ?? NSWorkspace.shared.box.deviceIcon(forModelIdentifier: metadata.modelIdentifier)
    }

    /// The same glyph unsquared, or `nil` where `machineIcon(for:)` falls back to a picture.
    private static func machineSymbol(for engine: RuntimeEngine) -> NSImage? {
        let metadata = engine.hostInfo.metadata
        return DeviceGlyph.symbolImage(
            forModelIdentifier: metadata.modelIdentifier,
            operatingSystemVersion: metadata.osVersion,
            isSimulator: metadata.isSimulator,
        )
    }

    /// Fallback for attached processes that Launch Services knows nothing about.
    /// `NSRunningApplication(processIdentifier:)` only resolves registered GUI
    /// applications, so daemons (launchservicesd, rapportd, ...) never make it
    /// into this type's cache and would otherwise fall back to an App Store
    /// placeholder symbol. The generic executable icon is what the attach picker
    /// already shows for those processes.
    ///
    /// Resolved once: `NSWorkspace.icon(for:)` is expensive, and the source menu
    /// re-resolves an icon for every engine each time the engine list changes.
    private static let genericExecutableIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    // MARK: - Icons of Their Own

    /// The icon resolved for `engine`, or `nil` when there is none — a daemon
    /// with no bundle, or a mirrored engine whose descriptor carried no bytes.
    private func cachedIcon(for engine: RuntimeEngine) -> NSImage? {
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
    /// A test gets a provider of its own that follows no engine manager (see
    /// `init(followsRuntimeEngineManager:)`): the live one would start the
    /// process-wide manager the first time a test shows an engine's icon.
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeEngineIconProvider.shared })
    public var runtimeEngineIconProvider: RuntimeEngineIconProvider = MainActor.assumeIsolated { RuntimeEngineIconProvider(followsRuntimeEngineManager: false) }
}

extension RuntimeEngineIconProvider: RuntimeEngineIconProviding {}

/// The live value of RuntimeViewerAppCore's `runtimeEngineIconProviding`: the same provider the app
/// reaches through `runtimeEngineIconProvider`.
extension RuntimeEngineIconProvidingKey: DependencyKey {
    package static var liveValue: any RuntimeEngineIconProviding {
        MainActor.assumeIsolated { RuntimeEngineIconProvider.shared }
    }
}
#endif
