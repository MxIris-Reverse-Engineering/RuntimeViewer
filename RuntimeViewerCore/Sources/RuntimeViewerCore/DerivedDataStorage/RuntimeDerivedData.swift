import Foundation
import FoundationToolbox

/// Derived data: what a process serving an engine works out from the images
/// of the dyld shared cache with its own code, kept on disk so that the same
/// code on the same system does not work it out again on the next launch —
/// what Xcode's DerivedData is to a build. The proposal `derived-data`
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

    /// Turns derived data on for the offline engine this process serves —
    /// called once, at the offline service's entry point. Unlike
    /// `enableInThisProcess()` it gives the process no store of its own:
    /// `offlineStore(for:isSharedCacheImage:)` makes one from the cache the
    /// engine reads, since this Mac's identity and this process's mapped
    /// cache say nothing about a cache read from disk.
    public static func enableForOfflineEngineInThisProcess() {
        isEnabledForOfflineEngine.withLock { $0 = true }
    }

    private static let isEnabledForOfflineEngine = Mutex(false)

    /// The derived data of an engine reading `file`, kept under the identity
    /// of the dyld shared cache it reads its cache images from: the file
    /// itself when it is a cache, this Mac's when it is paired with this
    /// Mac's, the registered cache's otherwise. Only that cache's images are
    /// kept (`isSharedCacheImage`), and the store never cleans up — its
    /// directory is either this Mac's, which the local services clean up, or
    /// an offline cache's, which only Delete Derived Data removes.
    ///
    /// `nil` unless the offline service turned it on, outside a RuntimeViewer
    /// application, for a file read alone, or when the cache cannot be read.
    static func offlineStore(for file: RuntimeOfflineFile, isSharedCacheImage: @escaping @Sendable (String) -> Bool) -> RuntimeDerivedDataStore? {
        guard isEnabledForOfflineEngine.withLock({ $0 }),
              let location = RuntimeDerivedDataLocation.enclosingApplication(of: .main),
              let system = systemIdentity(forCacheImagesOf: file),
              let producer = RuntimeDerivedDataProducerIdentity.currentProcess()
        else { return nil }
        #log(.info, "Offline derived data at \(location.rootURL.path, privacy: .public), system \(system.directoryName, privacy: .public), producer \(producer.directoryName, privacy: .public)")
        return RuntimeDerivedDataStore(location: location, system: system, producer: producer, isSharedCacheImage: isSharedCacheImage, cleansUpOnFirstUse: false)
    }

    /// Whose cache images an engine reading `file` reads; `nil` for a file
    /// read alone, or a cache that cannot be read.
    static func systemIdentity(forCacheImagesOf file: RuntimeOfflineFile) -> RuntimeDerivedDataSystemIdentity? {
        if case .dyldSharedCache = file.content {
            return (try? RuntimeDyldSharedCacheSummary(contentsOf: file.url)).flatMap(RuntimeDerivedDataSystemIdentity.offlineCache)
        }
        switch file.dependencyCache {
        case nil:
            return nil
        case .systemDyldSharedCache:
            return RuntimeDerivedDataSystemIdentity.current()
        case .dyldSharedCache(let url):
            return (try? RuntimeDyldSharedCacheSummary(contentsOf: url)).flatMap(RuntimeDerivedDataSystemIdentity.offlineCache)
        }
    }

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
