import Foundation
import FoundationToolbox

/// Derived data: what a process serving an engine works out from the images
/// of the dyld shared cache with its own code, kept on disk so that the same
/// code on the same system does not work it out again on the next launch —
/// what Xcode's DerivedData is to a build. The proposal `draft-derived-data`
/// is the contract; `RuntimeDerivedDataStore` is where it lives.
///
/// **Off unless a process turns it on.** The two processes that serve the
/// app's engines — the local-runtime XPC service and the Mac Catalyst
/// service — call `enableInThisProcess()` at their entry points, before any
/// engine connects. Every other process leaves it off: the app itself, whose
/// Bonjour server engine answers commands in its own process; the
/// command-line host; the Catalyst helper application; an injected payload;
/// a test, which hands an engine a store of its own instead. Forgetting the
/// call breaks nothing — the process only goes without derived data — so,
/// unlike the command extensions, it is not an obligation of every process
/// that links Core.
@Loggable(.private)
public enum RuntimeDerivedData {
    /// Turns derived data on for this process. Called once, at the entry
    /// point of the two processes that serve an engine and keep derived
    /// data — the local-runtime XPC service and the Mac Catalyst service —
    /// before any engine connects. Every other process leaves it off, the
    /// app's own process included.
    public static func enableInThisProcess() {
        isEnabled.withLock { $0 = true }
    }

    static var isEnabledInThisProcess: Bool {
        isEnabled.withLock { $0 }
    }

    private static let isEnabled = Mutex(false)

    /// The process's store: made the first time an enabled process asks,
    /// from the application around its bundle, its system and its code —
    /// `nil` when any of the three cannot be told, which leaves the process
    /// without derived data. Not behind `@Dependency`, as project singletons
    /// otherwise are: `RuntimeViewerCore` does not depend on
    /// swift-dependencies, nothing outside this file reaches it, and a test
    /// gives an engine a store of its own
    /// (`RuntimeEngine.useDerivedDataStore(_:)`).
    fileprivate static let processStore: RuntimeDerivedDataStore? = makeProcessStore()

    /// A function rather than the initializer's own closure: `#log` refers
    /// to `Self`, which a stored property's initializer cannot.
    private static func makeProcessStore() -> RuntimeDerivedDataStore? {
        guard let location = RuntimeDerivedDataLocation.enclosingApplication(of: .main) else {
            #log(.default, "No derived data: \(Bundle.main.bundlePath, privacy: .public) is not inside a RuntimeViewer application")
            return nil
        }
        guard let system = RuntimeDerivedDataSystemIdentity.current() else {
            #log(.default, "No derived data: this process's system cannot be told")
            return nil
        }
        guard let producer = RuntimeDerivedDataProducerIdentity.currentProcess() else {
            #log(.default, "No derived data: the image holding RuntimeViewerCore cannot be identified")
            return nil
        }
        #log(.info, "Derived data at \(location.rootURL.path, privacy: .public), system \(system.directoryName, privacy: .public), producer \(producer.directoryName, privacy: .public)")
        return RuntimeDerivedDataStore(location: location, system: system, producer: producer)
    }
}

extension RuntimeEngine {
    /// The derived data a corpus store of this process reads and writes:
    /// the process's store when derived data is on here, `nil` otherwise.
    static var processDerivedDataStore: RuntimeDerivedDataStore? {
        guard RuntimeDerivedData.isEnabledInThisProcess else { return nil }
        return RuntimeDerivedData.processStore
    }
}
