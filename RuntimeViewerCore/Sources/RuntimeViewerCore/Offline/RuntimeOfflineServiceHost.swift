#if os(macOS)

import Foundation
public import FoundationToolbox
public import RuntimeViewerCommunication

/// The offline service's whole job: read the file the app names, and serve it.
///
/// The service's `main.swift` builds one of these around
/// `RuntimeXPCServiceListenerConnection.embeddedService()` and calls
/// `activate()`. Nothing is read before the app attaches: its first `hello`
/// carries the file (``RuntimeOfflineService``), and before that `hello` is
/// answered this host opens the file, connects an engine reading it and
/// installs the engine's commands through a `RuntimeLocalRuntimeServiceHost`
/// — the same host the local runtime service runs, here started after the
/// listener activated rather than before. A file that cannot be read fails
/// the `hello`, and with it the app's connect, carrying the reason. Tests
/// build the same type around an anonymous listener.
///
/// One instance serves one file for its whole life: a later `hello` waits
/// for the same launch.
@Loggable(.private)
public final class RuntimeOfflineServiceHost: @unchecked Sendable {
    private let connection: RuntimeXPCServiceListenerConnection

    @Mutex
    private var serviceHost: RuntimeLocalRuntimeServiceHost?

    public init(connection: RuntimeXPCServiceListenerConnection) {
        self.connection = connection
        connection.setLaunchHandler { [weak self] payload in
            guard let self else { return }
            try await self.launch(with: payload)
        }
    }

    /// The engine reading the file, once the first `hello` named it.
    public var engine: RuntimeEngine? {
        serviceHost?.engine
    }

    /// Starts accepting the app. For the embedded service this is `xpc_main`
    /// and does not return.
    public func activate() {
        connection.activate()
    }

    public func stop() async {
        if let serviceHost {
            await serviceHost.stop()
        } else {
            connection.stop()
        }
    }

    private func launch(with payload: Data) async throws {
        Self.raiseDescriptorLimitForReadingFiles()
        let file = try RuntimeOfflineService.file(fromLaunchPayload: payload)
        let engine = try RuntimeEngine(reading: file, engineID: "offline-service.\(ProcessInfo.processInfo.processIdentifier)")
        let catalog = engine.imageCatalog
        if let derivedDataStore = RuntimeDerivedData.offlineStore(for: file, isSharedCacheImage: { catalog.isSharedCacheImage($0) }) {
            await engine.useDerivedDataStore(derivedDataStore)
        }
        let serviceHost = RuntimeLocalRuntimeServiceHost(engine: engine, connection: connection)
        try await serviceHost.start()
        self.serviceHost = serviceHost
        #log(.info, "Offline service reading \(file.displayName, privacy: .public)")
    }

    /// Raises this process's soft limit on open descriptors to the most
    /// `setrlimit(2)` advises asking for, `min(OPEN_MAX, rlim_max)`.
    ///
    /// launchd starts a service with room for 256, and a dyld shared cache
    /// read whole takes several hundred: MachOKit, the Swift reader and the
    /// Objective-C reader each map every one of its eighty-odd files, and a
    /// file paired with this Mac's cache reads that cache besides. Until this
    /// the service got by on the 2,304 more that CoreFoundation adds the first
    /// time anything in the process touches `CFSocket` — an accident of what
    /// the process links, not a limit anything chose.
    private static func raiseDescriptorLimitForReadingFiles() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let advisedLimit = min(rlim_t(OPEN_MAX), limit.rlim_max)
        guard limit.rlim_cur < advisedLimit else { return }
        limit.rlim_cur = advisedLimit
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            let reason = String(cString: strerror(errno))
            #log(.error, "Could not raise the descriptor limit to \(advisedLimit, privacy: .public): \(reason, privacy: .public)")
        }
    }
}

#endif
