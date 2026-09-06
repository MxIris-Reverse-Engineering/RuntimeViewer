import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

/// Turns a ``SourceSelector`` into a connected engine, and answers the source
/// commands (`sources`, `attach`, `detach`) that address the host's set of
/// sources rather than one engine.
///
/// ``LocalSourceResolver`` serves `.local` from one in-process engine and
/// nothing else; ``EngineManagerSourceResolver`` serves everything a
/// `RuntimeEngineManager` knows.
public protocol SourceResolving: Sendable {
    func resolve(_ selector: SourceSelector) async throws -> RuntimeEngine

    /// Every source the host serves right now, grouped by host. Must not
    /// start an engine.
    func listSources() async -> SourcesResult

    /// Injects into a running process and returns the source that reaches it.
    /// `progress` is called as the attach moves through its phases.
    func attach(_ target: AttachTarget, progress: @escaping @Sendable (CommandProgress) async -> Void) async throws -> AttachResult

    /// Drops an attached process or a Bonjour peer.
    func detach(_ selector: SourceSelector) async throws -> DetachResult

    /// Images the resolver's engines have indexed so far, for `host status`.
    /// Must not start an engine.
    func loadedImagePaths() async -> [String]

    /// Stops every engine the resolver started. Called once when the host exits.
    func shutdown() async
}

/// Serves `.local` from one lazily connected in-process engine and refuses
/// every other selector and every source command.
public actor LocalSourceResolver: SourceResolving {
    private var engine: RuntimeEngine?
    private var connectTask: Task<RuntimeEngine, any Error>?
    private let engineID: String

    /// - Parameter engine: An already connected engine to serve instead of
    ///   creating one. Tests share an engine that has loaded its images once.
    public init(engine: RuntimeEngine? = nil, engineID: String = "runtime-viewer-cli.local") {
        self.engine = engine
        self.engineID = engineID
    }

    public func resolve(_ selector: SourceSelector) async throws -> RuntimeEngine {
        guard case .local = selector else {
            throw CommandFailure(
                code: .sourceUnavailable,
                message: "Source '\(selector)' is not available: this host serves the local runtime only. Pass --source local or omit --source."
            )
        }
        if let engine {
            return engine
        }
        if let connectTask {
            return try await connectTask.value
        }
        let task = Task { [engineID] in
            let engine = RuntimeEngine(source: .local, engineID: engineID)
            try await engine.connect()
            return engine
        }
        connectTask = task
        do {
            let engine = try await task.value
            self.engine = engine
            return engine
        } catch {
            connectTask = nil
            throw CommandFailure(code: .internalError, message: "The local runtime engine failed to start: \(error.localizedDescription)")
        }
    }

    public func listSources() async -> SourcesResult {
        let source: SourceInfo
        let hostIdentifier: String
        if let engine {
            source = SourceInfo(engine: engine)
            hostIdentifier = engine.hostInfo.hostID
        } else {
            // Not started yet: describe what the first command will bring up
            // without bringing it up.
            source = SourceInfo(engineIdentifier: engineID, displayName: RuntimeSource.local.description, kind: .local, selector: .local, stableIdentity: nil, isConnected: false)
            hostIdentifier = "local"
        }
        return SourcesResult(hosts: [SourceHost(hostIdentifier: hostIdentifier, hostName: RuntimeNetworkBonjour.localHostName, sources: [source])])
    }

    public func attach(_ target: AttachTarget, progress: @escaping @Sendable (CommandProgress) async -> Void) async throws -> AttachResult {
        throw CommandFailure(code: .sourceUnavailable, message: "This host serves the local runtime only and cannot attach to processes.")
    }

    public func detach(_ selector: SourceSelector) async throws -> DetachResult {
        throw CommandFailure(code: .sourceUnavailable, message: "This host serves the local runtime only; there is nothing to detach.")
    }

    public func loadedImagePaths() async -> [String] {
        guard let engine else { return [] }
        return await engine.loadedImagePaths.sorted()
    }

    public func shutdown() async {
        connectTask?.cancel()
        connectTask = nil
        if let engine {
            await engine.stop()
        }
        engine = nil
    }
}
