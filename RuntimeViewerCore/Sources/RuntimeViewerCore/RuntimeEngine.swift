import MachOKit
public import FoundationToolbox
import RuntimeViewerCoreObjC
public import Foundation
public import Combine
public import RuntimeViewerCommunication
import Demangling
import OrderedCollections

// public import Version

// MARK: - RuntimeEngine.State

extension RuntimeEngine {
    /// Represents the current state of the RuntimeEngine.
    public enum State: Sendable, Equatable {
        /// The engine is being initialized.
        case initializing

        /// The engine is running locally without a remote connection.
        case localOnly

        /// The engine is attempting to connect to a remote source.
        case connecting

        /// The engine is connected to a remote source.
        case connected

        /// The engine has been disconnected from the remote source.
        case disconnected(error: RuntimeConnectionError?)

        /// Returns `true` if the engine is ready to process requests.
        public var isReady: Bool {
            switch self {
            case .localOnly,
                 .connected:
                return true
            case .initializing,
                 .connecting,
                 .disconnected:
                return false
            }
        }
    }
}

// MARK: - RuntimeEngine

@Loggable(.private)
public actor RuntimeEngine {
    enum CommandNames: String, CaseIterable {
        case imageList
        case imageNodes
        case loadImage
        case isImageLoaded
        case isImageIndexed
        case mainExecutablePath
        case loadImageForBackgroundIndexing
        case canOpenImage
        case rpathsForImage
        case dependenciesForImage
        case patchImagePathForDyld
        case runtimeObjectHierarchy
        case runtimeRelationshipsForObject
        case runtimeObjectInfo
        case imageNameOfClassName
        case observeRuntime
        case runtimeInterfaceExportModuleInfo
        case runtimeInterfaceForRuntimeObjectInImageWithOptions
        case runtimeObjectsOfKindInImage
        case runtimeObjectsInImage
        case imageDidLoad
        case memberAddresses
        case engineList
        case engineListChanged
        /// Shared side channel for `RuntimeEngineProgressRequest` pushes.
        /// Carries `RuntimeEngineProgressPush` frames routed by token, so a
        /// single command name serves every progress-bearing request type.
        case progressEvent
        case specializationRequest
        case specializationRequestForCandidate
        case runtimePreflight
        case specialize
        case dataDidChange

        var commandName: String {
            "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine.\(rawValue)"
        }
    }

    public static let local: RuntimeEngine = {
        let runtimeEngine = RuntimeEngine(source: .local)
        Task {
            try await runtimeEngine.connect()
        }
        return runtimeEngine
    }()

    /// Callback for serving engine list requests. Set by RuntimeEngineManager.
    public static var engineListProvider: (() async -> [RuntimeRemoteEngineDescriptor])?

    /// Callback for handling engine list change notifications. Set by RuntimeEngineManager.
    public static var engineListChangedHandler: (([RuntimeRemoteEngineDescriptor], RuntimeEngine) async -> Void)?

    /// Globally unique identifier for this engine instance.
    public nonisolated let engineID: String

    public nonisolated let source: RuntimeSource

    public nonisolated let hostInfo: RuntimeHostInfo

    public nonisolated let originChain: [String]

    /// Whether this engine should load and push runtime data to connected clients.
    /// Set to `false` for management-only engines (e.g. Bonjour server) that only handle engine list operations.
    public nonisolated let pushesRuntimeData: Bool

    // MARK: - State Management

    private var connectionStateCancellable: AnyCancellable?

    /// Consumes connection-state events strictly in arrival order. The Combine
    /// sink only forwards into an unbounded `AsyncStream`; this single task
    /// applies them one at a time. Spawning a `Task` per event (the previous
    /// shape) let the actor hops race, so a fast disconnect→connect pair could
    /// be applied out of order — leaving the engine stuck at `.disconnected` or
    /// mis-sequencing the `needsReregistrationOnConnect` handshake.
    private var connectionStateTask: Task<Void, Never>?
    private var connectionStateContinuation: AsyncStream<RuntimeConnectionState>.Continuation?

    /// Flag indicating that message handlers need to be re-registered on next connection.
    /// Set to `true` when a server connection disconnects, so that reconnection
    /// triggers handler re-registration and data push.
    private var needsReregistrationOnConnect = false

    private nonisolated let stateSubject = CurrentValueSubject<State, Never>(.initializing)

    /// Publisher that emits engine state changes.
    public nonisolated var statePublisher: some Publisher<State, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// The current engine state.
    public nonisolated var state: State {
        stateSubject.value
    }

    // MARK: - Data Properties

    public private(set) var imageList: [String] = []

    public internal(set) var loadedImagePaths: Set<String> = []

    private nonisolated let imageNodesSubject = CurrentValueSubject<[RuntimeImageNode], Never>([])

    public nonisolated var imageNodes: [RuntimeImageNode] {
        get { imageNodesSubject.value }
    }

    /// Publisher that emits image node changes. Accessible from any isolation context.
    public nonisolated var imageNodesPublisher: some Publisher<[RuntimeImageNode], Never> {
        imageNodesSubject.eraseToAnyPublisher()
    }

    /// Fine-grained data-change events. Prefer this over `reloadDataPublisher`
    /// when the consumer can apply incremental updates (e.g. the sidebar
    /// inserting a single specialized child rather than rebuilding its tree).
    public nonisolated var dataChangePublisher: some Publisher<RuntimeDataChange, Never> {
        dataChangeSubject.eraseToAnyPublisher()
    }

    private nonisolated let dataChangeSubject = PassthroughSubject<RuntimeDataChange, Never>()

    /// Back-compat unit signal derived from `dataChangePublisher`. Fires only
    /// for `.fullReload` events; subscribers wanting `.specializationAdded`
    /// (or any future fine-grained change) must use `dataChangePublisher`.
    public nonisolated var reloadDataPublisher: some Publisher<Void, Never> {
        dataChangeSubject
            .compactMap { change -> Void? in
                if case .fullReload = change { return () }
                return nil
            }
            .eraseToAnyPublisher()
    }

    /// Publisher that emits the image path each time `loadImage(at:)` succeeds.
    ///
    /// Fires on the local arm immediately after the image has been loaded and
    /// its ObjC/Swift sections cached. On a client engine, it fires when the
    /// server forwards an `.imageDidLoad` event (handled by
    /// `setupMessageHandlerForClient`).
    ///
    /// Marked `nonisolated` so subscribers (including Combine sinks in tests
    /// and downstream coordinators) can attach without an actor hop.
    public nonisolated var imageDidLoadPublisher: some Publisher<String, Never> {
        imageDidLoadSubject.eraseToAnyPublisher()
    }

    private nonisolated let imageDidLoadSubject = PassthroughSubject<String, Never>()

    /// In-flight progress routes keyed by the per-round-trip token minted in
    /// `dispatch(_:onProgress:)`. Inbound `progressEvent` pushes look up
    /// their token here and forward the decoded payload to the awaiting
    /// call's `onProgress` closure. Token routing (rather than a shared
    /// subject) keeps concurrent progress-bearing requests from
    /// cross-talking.
    private var progressRoutes: [String: @Sendable (Data) async -> Void] = [:]

    let objcSectionFactory: RuntimeObjCSectionFactory

    let swiftSectionFactory: RuntimeSwiftSectionFactory

    /// Cross-image relationship resolver. Owns the `relationships(for:)`
    /// computation so this engine file carries only the dispatch wrapper.
    let relationshipsResolver: RuntimeRelationshipsResolver

    private let communicator = RuntimeCommunicator()

    /// The connection to the sender or receiver, established by `connect()`.
    private var connection: (any RuntimeConnection)?

    /// Coordinator for background indexing batches that load and index images
    /// without blocking the main runtime data flow. `lazy` so it captures
    /// `self` only after all other stored properties are initialized; the
    /// actor's isolation guarantees the lazy initialization is single-threaded.
    public private(set) lazy var backgroundIndexingManager: RuntimeBackgroundIndexingManager =
        .init(engine: self)

    public init(
        source: RuntimeSource,
        engineID: String = UUID().uuidString,
        hostInfo: RuntimeHostInfo = RuntimeHostInfo(
            hostID: RuntimeNetworkBonjour.localInstanceID,
            hostName: RuntimeNetworkBonjour.localHostName,
        ),
        originChain: [String] = [RuntimeNetworkBonjour.localInstanceID],
        pushesRuntimeData: Bool = true,
    ) {
        self.engineID = engineID
        self.source = source
        self.hostInfo = hostInfo
        self.originChain = originChain
        self.pushesRuntimeData = pushesRuntimeData
        self.objcSectionFactory = .init()
        self.swiftSectionFactory = .init()
        self.relationshipsResolver = .init(objcSectionFactory: objcSectionFactory, swiftSectionFactory: swiftSectionFactory)
        #log(.info, "Initializing RuntimeEngine with source: \(String(describing: source), privacy: .public)")
    }

    public func connect(credential: RuntimeConnectionCredential? = nil) async throws {
        if let role = source.remoteRole {
            stateSubject.send(.connecting)

            switch role {
            case .server:
                #log(.info, "Starting as server")
                connection = try await communicator.connect(to: source, credential: credential) { connection in
                    self.connection = connection
                    self.setupMessageHandlerForServer()
                    self.observeConnectionState(connection)
                }
                #log(.info, "Server connection established")
                if pushesRuntimeData {
                    await observeRuntime()
                }
                stateSubject.send(.connected)
            case .client:
                #log(.info, "Starting as client for source: \(String(describing: self.source), privacy: .public)")
                connection = try await communicator.connect(to: source, credential: credential) { connection in
                    #log(.debug, "[EngineMirroring] client connection modifier called for \(String(describing: self.source), privacy: .public), connection state: \(String(describing: connection.state), privacy: .public)")
                    self.connection = connection
                    self.setupMessageHandlerForClient()
                    self.observeConnectionState(connection)
                }
                #log(.info, "Client connected successfully to \(String(describing: self.source), privacy: .public)")
                stateSubject.send(.connected)
            }
        } else {
            #log(.debug, "No remote role, observing local runtime")
            await observeRuntime()
            stateSubject.send(.localOnly)
        }
    }

    /// Observes the connection state and updates the engine state accordingly.
    private func observeConnectionState(_ connection: any RuntimeConnection) {
        // Serialize state events through one consumer so they are applied in
        // arrival order (see `connectionStateTask`).
        connectionStateTask?.cancel()
        connectionStateContinuation?.finish()

        let (stream, continuation) = AsyncStream<RuntimeConnectionState>.makeStream(bufferingPolicy: .unbounded)
        connectionStateContinuation = continuation
        connectionStateCancellable = connection.statePublisher
            .sink { state in
                continuation.yield(state)
            }
        connectionStateTask = Task { [weak self] in
            for await state in stream {
                await self?.handleConnectionStateChange(state)
            }
        }
    }

    /// Handles connection state changes and updates the engine state.
    private func handleConnectionStateChange(_ connectionState: RuntimeConnectionState) {
        switch connectionState {
        case .connecting:
            #log(.info, "Connection state -> connecting (source: \(String(describing: self.source), privacy: .public))")
            stateSubject.send(.connecting)
        case .connected:
            #log(.info, "Connection state -> connected (source: \(String(describing: self.source), privacy: .public))")
            stateSubject.send(.connected)
            // Re-register handlers and push data when server reconnects to a new client
            if needsReregistrationOnConnect, source.remoteRole == .server {
                needsReregistrationOnConnect = false
                #log(.info, "Server reconnected, re-registering handlers and pushing data")
                setupMessageHandlerForServer()
                if pushesRuntimeData {
                    Task { await self.observeRuntime() }
                }
            }
        case .disconnected(let error):
            if let error {
                #log(.error, "Connection state -> disconnected with error: \(error.localizedDescription, privacy: .public) (source: \(String(describing: self.source), privacy: .public))")
            } else {
                #log(.info, "Connection state -> disconnected (source: \(String(describing: self.source), privacy: .public))")
            }
            stateSubject.send(.disconnected(error: error))
            if source.remoteRole == .server {
                needsReregistrationOnConnect = true
            }
        }
    }

    /// Stops the engine and its connection.
    public func stop() {
        connectionStateTask?.cancel()
        connectionStateTask = nil
        connectionStateContinuation?.finish()
        connectionStateContinuation = nil
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        connection?.stop()
        stateSubject.send(.disconnected(error: nil))
        #log(.info, "RuntimeEngine stopped")
    }

    private func setupMessageHandlerForServer() {
        #log(.debug, "Setting up server message handlers")
        guard let connection else {
            #log(.default, "Connection is nil when setting up server message handlers")
            return
        }
        // Shared registry — same set of commands that
        // `RuntimeEngineProxyServer.setupRequestHandlers()` installs.
        // Progress-bearing commands (`runtimeObjectsInImage`) are included:
        // `registerProgress` relays their progress pushes automatically, so
        // no server-only override is needed here anymore.
        Self.registerSharedHandlers(on: connection, engine: self)

        // Server-only: manager-layer engine list lookup. Not part of the
        // shared registry because `RuntimeEngineProxyServer` runs below the
        // manager and has no engine list of its own.
        setMessageHandlerBinding(forName: .engineList) { _ -> [RuntimeRemoteEngineDescriptor] in
            #log(.debug, "[EngineMirroring] engineList handler called, provider set: \(RuntimeEngine.engineListProvider != nil, privacy: .public)")
            let result = await RuntimeEngine.engineListProvider?() ?? []
            #log(.debug, "[EngineMirroring] engineList handler returning \(result.count, privacy: .public) descriptors")
            return result
        }
        #log(.debug, "Server message handlers setup complete")
    }

    private func setupMessageHandlerForClient() {
        #log(.debug, "Setting up client message handlers for source: \(String(describing: self.source), privacy: .public)")
        setMessageHandlerBinding(forName: .imageList) { $0.imageList = $1 }
        setMessageHandlerBinding(forName: .imageNodes) { $0.setImageNodes($1) }
        setMessageHandlerBinding(forName: .dataDidChange) { (engine: RuntimeEngine, change: RuntimeDataChange) in
            engine.dataChangeSubject.send(change)
        }
        setMessageHandlerBinding(forName: .imageDidLoad) { (engine: RuntimeEngine, path: String) in
            engine.imageDidLoadSubject.send(path)
        }
        setMessageHandlerBinding(forName: .progressEvent) { (engine: RuntimeEngine, push: RuntimeEngineProgressPush) in
            await engine.routeProgressPush(push)
        }
        setMessageHandlerBinding(forName: .engineListChanged) { (engine: RuntimeEngine, descriptors: [RuntimeRemoteEngineDescriptor]) in
            #log(.debug, "[EngineMirroring] engineListChanged received: \(descriptors.count, privacy: .public) descriptors, handler set: \(RuntimeEngine.engineListChangedHandler != nil, privacy: .public)")
            await RuntimeEngine.engineListChangedHandler?(descriptors, engine)
        }
        #log(.debug, "Client message handlers setup complete")
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Void)) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) in
            try await function(object)(request)
        }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable, Response: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Response)) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) -> Response in
            let result = try await function(object)(request)
            return result
        }
    }

    private func setMessageHandlerBinding<Response: Codable>(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine, Response) async throws -> Void) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] (response: Response) in
            guard let self else { return }
            try await perform(self, response)
        }
    }

    private func setMessageHandlerBinding(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine) async throws -> Void) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] in
            guard let self else { return }
            try await perform(self)
        }
    }

    /// Overload for commands with no request body but a response.
    private func setMessageHandlerBinding<Response: Codable>(
        forName name: CommandNames,
        respond: @escaping (isolated RuntimeEngine) async throws -> Response,
    ) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] () -> Response in
            guard let self else { throw RequestError.senderConnectionIsLose }
            return try await respond(self)
        }
    }

    public func reloadData(isReloadImageNodes: Bool) {
        #log(.info, "Reloading data, isReloadImageNodes=\(isReloadImageNodes, privacy: .public)")
        imageList = DyldUtilities.imageNames()
        #log(.debug, "Loaded \(self.imageList.count, privacy: .public) images")
        if isReloadImageNodes {
            setImageNodes([DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode])
            #log(.debug, "Reloaded image nodes")
        }
        broadcast(.fullReload(isReloadImageNodes: isReloadImageNodes))
        #log(.info, "Data reload complete")
    }

    /// Emit a fine-grained data-change event. On the local arm the event is
    /// pushed directly to `dataChangeSubject`. On a server engine it is also
    /// serialized to the connected client via `.dataDidChange`; for
    /// `.fullReload`, the auxiliary `imageList` / `imageNodes` state is
    /// re-synced first so the client's mirrored view stays consistent.
    func broadcast(_ change: RuntimeDataChange) {
        Task {
            guard let role = source.remoteRole, role.isServer, let connection else {
                #log(.debug, "No remote connection, sending local data change \(String(describing: change), privacy: .public)")
                dataChangeSubject.send(change)
                return
            }
            #log(.debug, "Sending remote data change \(String(describing: change), privacy: .public)")
            if case .fullReload(let isReloadImageNodes) = change {
                try await connection.sendMessage(name: .imageList, request: imageList)
                if isReloadImageNodes {
                    try await connection.sendMessage(name: .imageNodes, request: imageNodes)
                }
            }
            try await connection.sendMessage(name: .dataDidChange, request: change)
            #log(.debug, "Remote data change sent successfully")
        }
    }

    private func observeRuntime() async {
        #log(.info, "Starting runtime observation")
        imageList = DyldUtilities.imageNames()
        #log(.debug, "Initial image list contains \(self.imageList.count, privacy: .public) images")

        await Task.detached {
            await self.setImageNodes([DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode])
        }.value
        #log(.debug, "Image nodes initialized")

        broadcast(.fullReload(isReloadImageNodes: true))
        #log(.info, "Runtime observation started")
    }

    private func setImageNodes(_ imageNodes: [RuntimeImageNode]) {
        self.imageNodesSubject.value = imageNodes
    }

    /// Forwards an `imageDidLoad` event to the connected client when this
    /// engine is acting as a server. On a local-only engine the local subject
    /// has already been signaled by the caller, so this is a no-op.
    private func sendRemoteImageDidLoadIfNeeded(path: String) {
        guard let role = source.remoteRole, role.isServer, let connection else { return }
        Task {
            try await connection.sendMessage(name: .imageDidLoad, request: path)
            #log(.debug, "Remote imageDidLoad sent for path: \(path, privacy: .public)")
        }
    }

    func _objects(in image: String) async throws -> [RuntimeObject] {
        #log(.debug, "Getting objects in image: \(image, privacy: .public)")
        let image = DyldUtilities.patchImagePathForDyld(image)
        let (isObjCSectionExisted, objcSection) = try await objcSectionFactory.section(for: image)
        let objcObjects = try await objcSection.allObjects()
        let (isSwiftSectionExisted, swiftSection) = try await swiftSectionFactory.section(for: image)
        let swiftObjects = try await swiftSection.allObjects()
        if !isObjCSectionExisted || !isSwiftSectionExisted {
            loadedImagePaths.insert(image)
        }
        #log(.debug, "Found \(objcObjects.count, privacy: .public) ObjC and \(swiftObjects.count, privacy: .public) Swift objects")
        return objcObjects + swiftObjects
    }

    func _interface(for name: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
        let rawInterface: RuntimeObjectInterface?

        switch name.kind {
        case .swift:
            let swiftSection = await swiftSectionFactory.existingSection(for: name.imagePath)
            try await swiftSection?.updateConfiguration(using: options.swiftInterfaceOptions, transformer: options.transformer.swift)
            return try? await swiftSection?.interface(for: name)
        case .c,
             .objc:
            let objcSection = await objcSectionFactory.existingSection(for: name.imagePath)
            let objcTransformer = options.transformer.objc
            if let interface = try? await objcSection?.interface(for: name, using: options.objcHeaderOptions, transformer: objcTransformer) {
                return interface
            } else {
                switch name.kind {
                case .objc(.type(let kind)):
                    switch kind {
                    case .class:
                        return try? await objcSectionFactory.section(for: .class(name.name))?.interface(for: name, using: options.objcHeaderOptions, transformer: objcTransformer)
                    case .protocol:
                        return try? await objcSectionFactory.section(for: .protocol(name.name))?.interface(for: name, using: options.objcHeaderOptions, transformer: objcTransformer)
                    }
                default:
                    rawInterface = nil
                }
            }
        }

        return rawInterface
    }
}

// MARK: - Requests

extension RuntimeEngine {
    public enum EngineError: Swift.Error, LocalizedError {
        case imageNotIndexed(imagePath: String)
        case typeNotGeneric
        case unsupportedGenericParameter(description: String)
        case specializationParameterNotFound(name: String)
        case specializationCandidateNotFound(parameterName: String, candidateDisplayName: String)
        /// Nested specialization for a `.boundGeneric` argument failed.
        /// `parameterName` is the outer parameter that owns the binding;
        /// `underlying` is the inner error's `localizedDescription` so it
        /// can cross the wire without depending on `@_spi(Support)` types.
        case boundGenericInnerFailed(parameterName: String, underlying: String)
        /// The user-selected candidate's defining image is not currently
        /// indexed by the engine that received the request — typically a
        /// cross-image candidate surfaced by the shared sub-indexer
        /// aggregate but not loaded for inspection on this side.
        case unindexedCandidate(displayName: String, imagePath: String)

        public var errorDescription: String? {
            switch self {
            case .imageNotIndexed(let imagePath):
                return "Image is not indexed: \(imagePath)"
            case .typeNotGeneric:
                return "This type is not generic."
            case .unsupportedGenericParameter(let description):
                return description
            case .specializationParameterNotFound(let name):
                return "Specialization parameter not found: \(name)"
            case .specializationCandidateNotFound(let parameterName, let candidateDisplayName):
                return "Candidate '\(candidateDisplayName)' is not available for parameter '\(parameterName)' in this image's index."
            case .boundGenericInnerFailed(let parameterName, let underlying):
                return "Inner specialization for parameter '\(parameterName)' failed: \(underlying)"
            case .unindexedCandidate(let displayName, let imagePath):
                return "Candidate '\(displayName)' is defined in an image that has not been indexed yet (\(imagePath)). Load the image first and retry."
            }
        }
    }

    enum RequestError: Swift.Error {
        case senderConnectionIsLose
    }

    /// Dispatch the request against this engine. On a client engine the call
    /// is serialized and forwarded to the connected server; otherwise the
    /// local `RuntimeEngineRequest.perform(on:)` implementation runs.
    ///
    /// Lives in this file rather than `RuntimeEngineRequest.swift` so it can read
    /// the file-private `connection` directly without widening visibility.
    func dispatch<R: RuntimeEngineRequest>(_ request: R) async throws -> R.Response {
        if let remoteRole = source.remoteRole, remoteRole.isClient {
            guard let connection else { throw RequestError.senderConnectionIsLose }
            return try await connection.sendMessage(name: R.commandName, request: request)
        }
        return try await request.perform(on: self)
    }

    /// Progress-request overload of `dispatch(_:)` with no progress listener.
    /// Exists so plain call sites stay wire-correct: a progress request must
    /// always ship the `RuntimeEngineProgressEnvelope` (here with a `nil`
    /// token) because the peer's handler decodes the envelope, not the bare
    /// request. Being more constrained than the base overload, Swift selects
    /// this one automatically for any `RuntimeEngineProgressRequest` conformer.
    func dispatch<R: RuntimeEngineProgressRequest>(_ request: R) async throws -> R.Response {
        try await dispatch(request, onProgress: nil)
    }

    /// Dispatch a progress-reporting request.
    ///
    /// Mirrors `dispatch(_:)` with a progress side channel. On a client engine
    /// the request is wrapped in a `RuntimeEngineProgressEnvelope` carrying a
    /// freshly minted token; the peer echoes that token on every
    /// `progressEvent` push, and `routeProgressPush` forwards the decoded
    /// payloads to `onProgress` until the response resolves. Locally the
    /// request's `perform(on:reportProgress:)` runs with `onProgress` wired
    /// straight through. Passing `nil` skips all progress machinery on both
    /// sides.
    func dispatch<R: RuntimeEngineProgressRequest>(
        _ request: R,
        onProgress: (@Sendable (R.Progress) async -> Void)?
    ) async throws -> R.Response {
        if let remoteRole = source.remoteRole, remoteRole.isClient {
            guard let connection else { throw RequestError.senderConnectionIsLose }
            guard let onProgress else {
                return try await connection.sendMessage(
                    name: R.commandName,
                    request: RuntimeEngineProgressEnvelope(progressToken: nil, request: request)
                )
            }
            let token = UUID().uuidString
            progressRoutes[token] = { payload in
                guard let progress = try? JSONDecoder().decode(R.Progress.self, from: payload) else { return }
                await onProgress(progress)
            }
            defer { progressRoutes.removeValue(forKey: token) }
            return try await connection.sendMessage(
                name: R.commandName,
                request: RuntimeEngineProgressEnvelope(progressToken: token, request: request)
            )
        }
        return try await request.perform(on: self, reportProgress: onProgress ?? { _ in })
    }

    /// Routes an inbound `progressEvent` push to the in-flight `dispatch`
    /// call it belongs to. Unknown tokens are dropped silently — the request
    /// already completed, or the push raced its own response. Awaiting the
    /// route inline (rather than detaching a `Task`) preserves push ordering:
    /// fire-and-forget handlers run on the message channel's serial tail.
    func routeProgressPush(_ push: RuntimeEngineProgressPush) async {
        guard let route = progressRoutes[push.token] else { return }
        await route(push.payload)
    }

    public func isImageLoaded(path: String) async throws -> Bool {
        try await dispatch(IsImageLoadedRequest(path: path))
    }

    func _isImageLoaded(path: String) -> Bool {
        imageList.contains(DyldUtilities.patchImagePathForDyld(path))
    }

    public func loadImage(at path: String) async throws {
        _ = try await dispatch(LoadImageRequest(path: path))
    }

    /// Local implementation of `loadImage(at:)`. Canonicalizes on entry so
    /// internal storage (loadedImagePaths, section factory caches) stays
    /// symmetric with reader-side lookups (isImageLoaded, isImageIndexed,
    /// _objects), all of which patch first. On macOS this is identity; on iOS
    /// Simulator it applies DYLD_ROOT_PATH so dyld's own image-name reports
    /// match. patchImagePathForDyld is idempotent — re-patching an already
    /// patched path is safe.
    func _loadImage(at path: String) async throws {
        let canonical = DyldUtilities.patchImagePathForDyld(path)
        try DyldUtilities.loadImage(at: canonical)
        _ = try await objcSectionFactory.section(for: canonical)
        _ = try await swiftSectionFactory.section(for: canonical)
        reloadData(isReloadImageNodes: false)
        loadedImagePaths.insert(canonical)
        imageDidLoadSubject.send(canonical)
        sendRemoteImageDidLoadIfNeeded(path: canonical)
    }

    public func imageName(ofObjectName name: RuntimeObject) async throws -> String? {
        try await dispatch(ImageNameOfObjectRequest(object: name))
    }

    public func interface(for object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
        try await dispatch(InterfaceRequest(object: object, options: options))
    }

    public func objects(in image: String) async throws -> [RuntimeObject] {
        try await dispatch(ObjectsInImageRequest(image: image), onProgress: nil)
    }

    public func objectsWithProgress(in image: String) -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let objects = try await dispatch(ObjectsInImageRequest(image: image)) { progress in
                        continuation.yield(.progress(progress))
                    }
                    continuation.yield(.completed(objects))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Local arm of `ObjectsInImageRequest`'s progress-bearing `perform`.
    /// Bridges the continuation-based indexing internals (section factories
    /// take a `LoadingEventContinuation`) to the closure-based
    /// `RuntimeEngineProgressRequest` reporting surface. The pump task awaits
    /// `reportProgress` per event, preserving order; it is drained before
    /// returning so no progress event can trail the response on the wire.
    func _objects(in image: String, reportProgress: @escaping @Sendable (RuntimeObjectsLoadingProgress) async -> Void) async throws -> [RuntimeObject] {
        let (stream, continuation) = AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error>.makeStream()
        let pump = Task {
            for try await event in stream {
                if case .progress(let progress) = event {
                    await reportProgress(progress)
                }
            }
        }
        do {
            let objects = try await _localObjectsWithProgress(in: image, continuation: continuation)
            continuation.finish()
            _ = await pump.result
            return objects
        } catch {
            continuation.finish()
            _ = await pump.result
            throw error
        }
    }

    private func _localObjectsWithProgress(
        in image: String,
        continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error>.Continuation,
    ) async throws -> [RuntimeObject] {
        #log(.debug, "Getting objects with progress in image: \(image, privacy: .public)")
        let image = DyldUtilities.patchImagePathForDyld(image)
        let (isObjCSectionExisted, objcSection) = try await objcSectionFactory.section(for: image, progressContinuation: continuation)
        let objcObjects = try await objcSection.allObjects()
        let (isSwiftSectionExisted, swiftSection) = try await swiftSectionFactory.section(for: image, progressContinuation: continuation)
        let swiftObjects = try await swiftSection.allObjects()
        if !isObjCSectionExisted || !isSwiftSectionExisted {
            loadedImagePaths.insert(image)
        }
        #log(.debug, "Found \(objcObjects.count, privacy: .public) ObjC and \(swiftObjects.count, privacy: .public) Swift objects with progress")
        return objcObjects + swiftObjects
    }

    public func hierarchy(for object: RuntimeObject) async throws -> [String] {
        try await dispatch(HierarchyRequest(object: object))
    }

    func _hierarchy(for object: RuntimeObject) async throws -> [String] {
        switch object.kind {
        case .c:
            return []
        case .objc:
            return try await objcSectionFactory.existingSection(for: object.imagePath)?.classHierarchy(for: object) ?? []
        case .swift:
            return try await swiftSectionFactory.existingSection(for: object.imagePath)?.classHierarchy(for: object) ?? []
        }
    }

    /// Cross-image relationships for an inspectable target: every direct
    /// subclass (for classes) or conforming type (for protocols), unioned
    /// across all indexed images.
    ///
    /// The cross-image union itself lives in `RuntimeRelationshipsResolver`,
    /// which derives the indexed-image set straight from the section
    /// factories; this method keeps only the thin local/remote dispatch.
    /// The remote arm forwards the query to the connected server.
    public func relationships(for object: RuntimeObject) async throws -> RuntimeRelationships {
        try await dispatch(RelationshipsRequest(object: object))
    }

    func _relationships(for object: RuntimeObject) async -> RuntimeRelationships {
        await relationshipsResolver.relationships(for: object)
    }

    public func memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress] {
        try await dispatch(MemberAddressesRequest(object: object, memberName: memberName))
    }

    func _memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress] {
        switch object.kind {
        case .swift:
            return try await swiftSectionFactory.existingSection(for: object.imagePath)?.memberAddresses(for: object, memberName: memberName) ?? []
        case .objc:
            return try await objcSectionFactory.existingSection(for: object.imagePath)?.memberAddresses(for: object, memberName: memberName) ?? []
        default:
            return []
        }
    }

    /// Asks the connected peer for its shared engine list.
    ///
    /// On macOS the peer answers with a non-empty descriptor list; on platforms without
    /// `RuntimeEngineManager` (iOS, visionOS, etc.) the peer either returns an empty list
    /// or never replies. The default `timeout` of 5 s lets the caller fall through to the
    /// "treat as direct engine" branch instead of hanging forever on a flaky link
    /// (e.g. AWDL between iPhone and Mac).
    public func requestEngineList(timeout: TimeInterval = 5) async throws -> [RuntimeRemoteEngineDescriptor] {
        // Bypasses the standard `dispatch` because the client arm needs a
        // configurable per-call timeout, and the local arm always returns an
        // empty list (no engine-list provider runs on a non-server engine).
        guard let remoteRole = source.remoteRole, remoteRole.isClient else { return [] }
        guard let connection else { throw RequestError.senderConnectionIsLose }
        return try await connection.sendMessage(name: .engineList, timeout: timeout)
    }

    public func pushEngineListChanged(_ descriptors: [RuntimeRemoteEngineDescriptor]) async throws {
        let hasConnection = connection != nil
        let isServer = source.remoteRole?.isServer == true
        guard let connection, isServer else {
            #log(.debug, "[EngineMirroring] pushEngineListChanged skipped: connection=\(hasConnection, privacy: .public), isServer=\(isServer, privacy: .public)")
            return
        }
        #log(.debug, "[EngineMirroring] pushEngineListChanged sending \(descriptors.count, privacy: .public) descriptors")
        try await connection.sendMessage(name: .engineListChanged, request: descriptors)
        #log(.debug, "[EngineMirroring] pushEngineListChanged sent successfully")
    }
}

extension RuntimeConnection {
    func sendMessage(name: RuntimeEngine.CommandNames) async throws {
        return try await sendMessage(name: name.commandName)
    }

    func sendMessage<Request: Codable>(name: RuntimeEngine.CommandNames, request: Request) async throws {
        return try await sendMessage(name: name.commandName, request: request)
    }

    func sendMessage<Response: Codable>(name: RuntimeEngine.CommandNames) async throws -> Response {
        return try await sendMessage(name: name.commandName)
    }

    func sendMessage<Response: Codable>(name: RuntimeEngine.CommandNames, timeout: TimeInterval?) async throws -> Response {
        return try await sendMessage(name: name.commandName, timeout: timeout)
    }

    func sendMessage<Response: Codable>(name: RuntimeEngine.CommandNames, request: some Codable) async throws -> Response {
        return try await sendMessage(name: name.commandName, request: request)
    }
}

// MARK: - Export

extension RuntimeEngine {
    public enum RuntimeExportError: Error {
        case interfaceGenerationFailed(RuntimeObject)
    }

    public func exportInterfaces(
        with configuration: RuntimeInterfaceExportConfiguration,
        reporter: RuntimeInterfaceExportReporter,
    ) async throws {
        defer { reporter.finish() }
        let startTime = CFAbsoluteTimeGetCurrent()

        reporter.send(.phaseStarted(.preparing))
        let allObjects = try await objects(in: configuration.imagePath)
        reporter.send(.phaseCompleted(.preparing))

        reporter.send(.phaseStarted(.exporting))
        var results: [RuntimeInterfaceExportItem] = []
        var succeeded = 0
        var failed = 0
        var objcCount = 0
        var swiftCount = 0
        let total = allObjects.count

        for (index, object) in allObjects.enumerated() {
            try Task.checkCancellation()
            reporter.send(.objectStarted(object, current: index + 1, total: total))
            do {
                guard let runtimeInterface = try await interface(for: object, options: configuration.generationOptions) else {
                    throw RuntimeExportError.interfaceGenerationFailed(object)
                }
                let item = RuntimeInterfaceExportItem(
                    object: object,
                    plainText: runtimeInterface.interfaceString.string,
                    suggestedFileName: object.exportFileName,
                )
                results.append(item)
                succeeded += 1
                if item.isSwift { swiftCount += 1 } else { objcCount += 1 }
                reporter.send(.objectCompleted(object, runtimeInterface.interfaceString))
            } catch {
                failed += 1
                reporter.send(.objectFailed(object, error))
            }
        }
        reporter.send(.phaseCompleted(.exporting))

        reporter.send(.phaseStarted(.writing))

        var writeFailed = 0

        do {
            let objcItems = results.filter { !$0.isSwift }
            let swiftItems = results.filter { $0.isSwift }

            if !objcItems.isEmpty {
                switch configuration.objcFormat {
                case .singleFile:
                    try RuntimeInterfaceExportWriter.writeSingleFile(
                        items: objcItems,
                        to: configuration.directory,
                        imageName: configuration.imageName,
                    )
                case .directory:
                    let writeResult = try RuntimeInterfaceExportWriter.writeDirectory(
                        items: objcItems,
                        to: configuration.directory,
                    )
                    for (failedItem, writeError) in writeResult.failedItems {
                        reporter.send(.objectFailed(failedItem.object, writeError))
                    }
                    writeFailed += writeResult.failedItems.count
                }
            }

            if !swiftItems.isEmpty {
                switch configuration.swiftFormat {
                case .singleFile:
                    try RuntimeInterfaceExportWriter.writeSingleFile(
                        items: swiftItems,
                        to: configuration.directory,
                        imageName: configuration.imageName,
                    )
                case .directory:
                    let writeResult = try RuntimeInterfaceExportWriter.writeDirectory(
                        items: swiftItems,
                        to: configuration.directory,
                    )
                    for (failedItem, writeError) in writeResult.failedItems {
                        reporter.send(.objectFailed(failedItem.object, writeError))
                    }
                    writeFailed += writeResult.failedItems.count
                }
            }

            if configuration.includeMetadata {
                let module = try await dispatch(
                    ExportModuleInfoRequest(
                        imagePath: configuration.imagePath,
                        imageName: configuration.imageName
                    )
                )
                let metadata = RuntimeInterfaceExportMetadata.make(
                    configuration: configuration,
                    module: module,
                    objcInterfaceCount: objcCount,
                    swiftInterfaceCount: swiftCount,
                    succeeded: succeeded,
                    failed: failed + writeFailed,
                )
                try RuntimeInterfaceExportWriter.writeMetadata(metadata, to: configuration.directory)
            }

            reporter.send(.phaseCompleted(.writing))
        } catch {
            reporter.send(.phaseFailed(.writing, error))
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let result = RuntimeInterfaceExportResult(
            succeeded: succeeded,
            failed: failed + writeFailed,
            totalDuration: duration,
            objcCount: objcCount,
            swiftCount: swiftCount,
        )
        reporter.send(.completed(result))
    }
}
