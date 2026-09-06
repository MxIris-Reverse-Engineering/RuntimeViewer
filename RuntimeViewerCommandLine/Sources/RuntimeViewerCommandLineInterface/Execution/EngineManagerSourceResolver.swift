import Darwin
import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
#if os(macOS)
import RuntimeViewerEngineManagement
import RuntimeViewerHelperClient
#endif

/// Serves every source a `RuntimeEngineManager` knows: the local runtime, the
/// Mac Catalyst runtime, injected processes, Bonjour peers and mirrored
/// engines, plus `sources` / `attach` / `detach`.
///
/// Reads the manager through a ``SourceCatalog`` snapshot and injects through
/// a ``ProcessAttaching``, so the lookup rules and the attach flow's
/// bookkeeping are testable without a helper daemon or a live peer.
@Loggable
public final class EngineManagerSourceResolver: SourceResolving {
    public struct Configuration: Sendable {
        /// The manager brings its engines up after it is created: `.local` at
        /// once, the Catalyst helper and injected-process reconnection a
        /// little later. A selector that misses inside this window after the
        /// resolver was created is retried until the window closes, so the
        /// first command against a fresh host does not fail on timing.
        public var startupGracePeriod: Duration
        public var retryInterval: Duration
        /// The application bundle the payload and the Catalyst helper come
        /// from, when one was found. Only used to phrase failures.
        public var applicationBundleURL: URL?

        public init(startupGracePeriod: Duration = .seconds(8), retryInterval: Duration = .milliseconds(100), applicationBundleURL: URL? = nil) {
            self.startupGracePeriod = startupGracePeriod
            self.retryInterval = retryInterval
            self.applicationBundleURL = applicationBundleURL
        }
    }

    private let catalog: any SourceCatalog
    private let attacher: (any ProcessAttaching)?
    private let processDirectory: any ProcessDirectory
    /// Throws when the helper daemon cannot be reached; run before an attach
    /// so the failure names the daemon instead of a step inside injection.
    private let helperPreflight: @Sendable () async throws -> Void
    private let configuration: Configuration
    private let createdAt = ContinuousClock.now

    public init(
        catalog: any SourceCatalog,
        attacher: (any ProcessAttaching)?,
        processDirectory: any ProcessDirectory = LibprocProcessDirectory(),
        helperPreflight: @escaping @Sendable () async throws -> Void = {},
        configuration: Configuration = Configuration()
    ) {
        self.catalog = catalog
        self.attacher = attacher
        self.processDirectory = processDirectory
        self.helperPreflight = helperPreflight
        self.configuration = configuration
    }

    #if os(macOS)
    /// The production wiring: the manager as catalog, `RuntimeProcessAttacher`
    /// as attacher, the helper daemon connection as preflight.
    @MainActor
    public static func forEngineManager(
        _ engineManager: RuntimeEngineManager,
        injectClient: RuntimeInjectClient,
        helperServiceManager: HelperServiceManager,
        applicationBundleURL: URL?
    ) -> EngineManagerSourceResolver {
        EngineManagerSourceResolver(
            catalog: RuntimeEngineManagerCatalog(engineManager: engineManager),
            attacher: RuntimeProcessAttacherAdapter(attacher: RuntimeProcessAttacher(engineManager: engineManager, injectClient: injectClient)),
            helperPreflight: { try await helperServiceManager.ensureConnectedToTool() },
            configuration: Configuration(applicationBundleURL: applicationBundleURL)
        )
    }
    #endif

    // MARK: - Resolution

    public func resolve(_ selector: SourceSelector) async throws -> RuntimeEngine {
        while true {
            let snapshot = await catalog.snapshot()
            let failure: CommandFailure
            switch Self.lookup(selector, in: snapshot) {
            case .found(let engine) where engine.state.isReady:
                return engine
            case .found(let engine):
                failure = CommandFailure(
                    code: .sourceUnavailable,
                    message: "Source '\(selector)' (\(engine.source.description)) is not connected: \(Self.describe(engine.state))."
                )
            case .missing(let missingFailure):
                failure = missingFailure
            }
            guard isInsideStartupGracePeriod else {
                throw failure
            }
            try await Task.sleep(for: configuration.retryInterval)
        }
    }

    private var isInsideStartupGracePeriod: Bool {
        ContinuousClock.now - createdAt < configuration.startupGracePeriod
    }

    enum Lookup {
        case found(RuntimeEngine)
        case missing(CommandFailure)
    }

    /// The pure part of ``resolve(_:)``: which engine a selector names in a
    /// snapshot, or why none does.
    static func lookup(_ selector: SourceSelector, in snapshot: SourceCatalogSnapshot) -> Lookup {
        switch selector {
        case .local:
            if let engine = snapshot.systemEngines.first(where: { $0.source == .local }) {
                return .found(engine)
            }
            return .missing(CommandFailure(code: .sourceUnavailable, message: "The local runtime engine has not started yet; try again in a moment."))

        case .macCatalyst:
            if let engine = snapshot.systemEngines.first(where: { SourceKind(source: $0.source) == .macCatalyst }) {
                return .found(engine)
            }
            let reason = snapshot.catalystHelperFailure.map { " (\($0))" } ?? ""
            return .missing(CommandFailure(
                code: .sourceUnavailable,
                message: "The Mac Catalyst runtime is not available\(reason). It needs the helper daemon and the Catalyst helper inside RuntimeViewer.app: install the daemon in RuntimeViewer → Settings → Helper Service, then run `host restart`."
            ))

        case .attachedProcess(let processIdentifier):
            if let engine = snapshot.attachedEngines.first(where: { $0.source.identifier == String(processIdentifier) }) {
                return .found(engine)
            }
            return .missing(CommandFailure(
                code: .sourceUnavailable,
                message: "No attached process with pid \(processIdentifier). Run `attach \(processIdentifier)` first; `sources` lists what is attached."
            ))

        case .attachedProcessNamed(let name):
            let wanted = name.lowercased()
            let matches = snapshot.attachedEngines.filter { $0.source.description.lowercased() == wanted }
            switch matches.count {
            case 0:
                return .missing(CommandFailure(
                    code: .sourceUnavailable,
                    message: "No attached process named '\(name)'. `sources` lists what is attached; `attach \(name)` injects into a running process of that name."
                ))
            case 1:
                return .found(matches[0])
            default:
                let identifiers = matches.map { "pid:\($0.source.identifier)" }.joined(separator: ", ")
                return .missing(CommandFailure(
                    code: .sourceUnavailable,
                    message: "Several attached processes are named '\(name)': \(identifiers). Address one of them by pid."
                ))
            }

        case .engine(let identifier):
            if let engine = snapshot.allEngines.first(where: { $0.engineID == identifier }) {
                return .found(engine)
            }
            return .missing(CommandFailure(
                code: .sourceUnavailable,
                message: "No engine with identifier '\(identifier)'. Run `sources --wait 5` to rediscover peers; an identifier changes when its peer reconnects."
            ))
        }
    }

    private static func describe(_ state: RuntimeEngine.State) -> String {
        switch state {
        case .initializing: return "still initializing"
        case .localOnly: return "ready"
        case .connecting: return "still connecting"
        case .connected: return "ready"
        case .disconnected(let error):
            return "disconnected" + (error.map { " (\($0.localizedDescription))" } ?? "")
        }
    }

    // MARK: - Sources

    public func listSources() async -> SourcesResult {
        SourcesResult(snapshot: await catalog.snapshot())
    }

    // MARK: - Attach

    public func attach(_ target: AttachTarget, progress: @escaping @Sendable (CommandProgress) async -> Void) async throws -> AttachResult {
        guard let attacher else {
            throw CommandFailure(code: .sourceUnavailable, message: "This host cannot attach to processes.")
        }
        let process = try resolveProcess(target)

        // Already attached: answer with the existing engine instead of
        // injecting a second payload into the process.
        let snapshot = await catalog.snapshot()
        if let existing = snapshot.attachedEngines.first(where: { $0.source.identifier == String(process.processIdentifier) }) {
            return AttachResult(
                processName: existing.source.description,
                processIdentifier: process.processIdentifier,
                transport: SourceKind(source: existing.source) == .attachedSocket ? "localSocket" : "xpc",
                payloadPlatform: "macOS",
                selector: .selector(for: existing),
                engineIdentifier: existing.engineID,
                wasAlreadyAttached: true
            )
        }

        do {
            try await helperPreflight()
        } catch {
            throw CommandFailure(
                code: .helperUnavailable,
                message: "The helper daemon could not be reached (\(error.localizedDescription)). Install it in RuntimeViewer → Settings → Helper Service; attaching needs it."
            )
        }

        await progress(CommandProgress(phase: "preparing", detail: "\(process.name) (\(process.processIdentifier))"))
        let processName = process.name
        let outcome: AttachOutcome
        do {
            outcome = try await attacher.attach(name: process.name, processIdentifier: process.processIdentifier) { phase in
                Task { await progress(phase.progress(processName: processName)) }
            }
        } catch let failure as CommandFailure {
            throw failure
        } catch {
            throw attachFailure(error, processName: process.name)
        }
        #log(.info, "Attached to \(process.name, privacy: .public) (\(process.processIdentifier, privacy: .public)) over \(outcome.transport, privacy: .public)")

        let selector: SourceSelector = outcome.reachedOverBonjour
            ? .engine(identifier: outcome.engine.engineID)
            : .attachedProcess(processIdentifier: process.processIdentifier)
        return AttachResult(
            processName: process.name,
            processIdentifier: process.processIdentifier,
            transport: outcome.transport,
            payloadPlatform: outcome.payloadPlatform,
            selector: selector,
            engineIdentifier: outcome.engine.engineID,
            wasAlreadyAttached: false
        )
    }

    private func resolveProcess(_ target: AttachTarget) throws -> RunningProcess {
        switch target {
        case .processIdentifier(let processIdentifier):
            if let process = processDirectory.process(withIdentifier: processIdentifier) {
                return process
            }
            // Alive but not readable (another user's process, typically): the
            // daemon may still be able to inject, so keep going with a
            // placeholder name.
            if kill(processIdentifier, 0) == 0 || errno == EPERM {
                return RunningProcess(processIdentifier: processIdentifier, name: "pid \(processIdentifier)", executablePath: nil)
            }
            throw CommandFailure(code: .processNotFound, message: "No process with pid \(processIdentifier) is running.")

        case .processName(let name):
            let ownProcessIdentifier = getpid()
            let matches = processDirectory.runningProcesses().filter { $0.processIdentifier != ownProcessIdentifier && $0.matches(name: name) }
            switch matches.count {
            case 0:
                throw CommandFailure(code: .processNotFound, message: "No running process is named '\(name)'. The name is matched against the process name and the executable's file name, case-insensitively; a pid works too.")
            case 1:
                return matches[0]
            default:
                let listed = matches.map { "\($0.name) (\($0.processIdentifier))" }.joined(separator: ", ")
                throw CommandFailure(code: .ambiguousProcessName, message: "Several running processes are named '\(name)': \(listed). Attach by pid.")
            }
        }
    }

    private func attachFailure(_ error: any Error, processName: String) -> CommandFailure {
        #if os(macOS)
        if case RuntimeInjectClient.Error.serverFrameworkNotFound(let platform) = error {
            if let applicationBundleURL = configuration.applicationBundleURL {
                return CommandFailure(
                    code: .applicationBundleNotFound,
                    message: "\(applicationBundleURL.path) carries no \(platform.displayName) payload, and none is installed under /Library/Frameworks. Point the host at a RuntimeViewer.app that ships it (`host run --app-bundle`, or \(ApplicationBundleLocator.environmentVariable))."
                )
            }
            return CommandFailure(
                code: .applicationBundleNotFound,
                message: "No RuntimeViewer.app was found to take the \(platform.displayName) payload from, and none is installed under /Library/Frameworks. Install RuntimeViewer, or point the host at a copy with `host run --app-bundle <path>` or \(ApplicationBundleLocator.environmentVariable)."
            )
        }
        #endif
        return CommandFailure(code: .attachFailed, message: "Attaching to \(processName) failed: \(error.localizedDescription)")
    }

    // MARK: - Detach

    public func detach(_ selector: SourceSelector) async throws -> DetachResult {
        let snapshot = await catalog.snapshot()
        let engine: RuntimeEngine
        switch Self.lookup(selector, in: snapshot) {
        case .found(let found):
            engine = found
        case .missing(let failure):
            throw failure
        }
        let kind = SourceKind(source: engine.source)
        switch kind {
        case .attachedXPC, .attachedSocket, .bonjour:
            break
        case .local, .macCatalyst, .mirrored:
            throw CommandFailure(
                code: .invalidArgument,
                message: "'\(selector)' is a \(kind.rawValue) source and cannot be detached; only attached processes and Bonjour peers can."
            )
        }
        await catalog.terminate(engine)
        #log(.info, "Detached \(engine.source.description, privacy: .public) (\(engine.engineID, privacy: .public))")
        return DetachResult(selector: .selector(for: engine), engineIdentifier: engine.engineID, displayName: engine.source.description, kind: kind)
    }

    // MARK: - Host bookkeeping

    public func loadedImagePaths() async -> [String] {
        let snapshot = await catalog.snapshot()
        guard let engine = snapshot.systemEngines.first(where: { $0.source == .local }) else { return [] }
        return await engine.loadedImagePaths.sorted()
    }

    /// Nothing to do: the engines belong to the manager and die with the
    /// process, and the injected-process records must survive so the next host
    /// (or the app) reconnects to them.
    public func shutdown() async {}
}
