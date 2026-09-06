import Foundation
import RuntimeViewerCore

/// Turns a ``SourceSelector`` into a connected engine.
///
/// The seam later releases replace to serve attached processes, the Catalyst
/// helper and Bonjour peers; this release ships ``LocalSourceResolver`` only.
public protocol SourceResolving: Sendable {
    func resolve(_ selector: SourceSelector) async throws -> RuntimeEngine

    /// Images the resolver's engines have indexed so far, for `host status`.
    /// Must not start an engine.
    func loadedImagePaths() async -> [String]

    /// Stops every engine the resolver started. Called once when the host exits.
    func shutdown() async
}

/// Serves `.local` from one lazily connected in-process engine and refuses
/// every other selector.
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
