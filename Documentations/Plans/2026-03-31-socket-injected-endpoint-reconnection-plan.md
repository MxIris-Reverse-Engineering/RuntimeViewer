# Socket Injected Endpoint Reconnection Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable sandboxed (socket-based) injected apps to survive host app restarts and automatically reconnect, matching the existing XPC injected endpoint reconnection capability.

**Architecture:** The injected client (`RuntimeLocalSocketClientConnection`) gains automatic reconnection with periodic retry on disconnect. The host app (`RuntimeEngineManager`) persists socket injection records to a local JSON file, reads them on startup, checks process liveness, and recreates socket servers for alive injected processes. The injected client's retry loop reconnects to the recreated server.

**Tech Stack:** Swift, BSD sockets, Combine, Foundation (JSONEncoder/JSONDecoder, FileManager)

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Modify | `RuntimeViewerCore/.../Connections/RuntimeLocalSocketConnection.swift` | Add `ownStateSubject`, `pendingHandlers`, and auto-reconnect loop to `RuntimeLocalSocketClientConnection`; add `ownStateSubject` to `RuntimeLocalSocketServerConnection` |
| Modify | `RuntimeViewerUsingAppKit/.../Utils/RuntimeEngineManager.swift` | Persist/load socket injection records; reconnect socket endpoints on startup |

---

### Task 1: Add `ownStateSubject` to `RuntimeLocalSocketServerConnection`

The server connection replaces `underlyingConnection` on each new client accept, but the base class `statePublisher` is a computed property that returns the *current* underlying connection's publisher. Subscribers from before the swap never see the new connection's events. Adding `ownStateSubject` (same pattern as `RuntimeDirectTCPServerConnection`) fixes this.

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeLocalSocketConnection.swift:651-881`

- [ ] **Step 1: Add `ownStateSubject` property and override `statePublisher`/`state`**

Add after the existing `port` property (line 662):

```swift
/// Stable state subject that bridges state from underlying connections across reconnections.
private let ownStateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

override var statePublisher: AnyPublisher<RuntimeConnectionState, Never> {
    ownStateSubject.eraseToAnyPublisher()
}

override var state: RuntimeConnectionState {
    ownStateSubject.value
}
```

- [ ] **Step 2: Drive `ownStateSubject` from the accepted connection state**

Replace the `connectionStateCancellable` sink in `acceptConnectionLoop()` (lines 847-854) to bridge state through `ownStateSubject`:

```swift
// Observe connection state to restart accepting when disconnected
connectionStateCancellable = socketConnection.statePublisher
    .sink { [weak self] state in
        guard let self else { return }
        #log(.info, "Local socket connection state: \(String(describing: state), privacy: .public)")
        if state.isConnected {
            ownStateSubject.send(.connected)
        } else if state.isDisconnected {
            #log(.info, "Local socket client disconnected, waiting for new connection...")
            ownStateSubject.send(state)
            startAcceptingConnections()
        }
    }
```

- [ ] **Step 3: Send `.connecting` at the start of `startAcceptingConnections()`**

In `startAcceptingConnections()` (line 803), add before the dispatch:

```swift
private func startAcceptingConnections() {
    ownStateSubject.send(.connecting)
    #log(.info, "Waiting for local socket client connection on port \(self.port, privacy: .public)...")
    DispatchQueue.global().async { [weak self] in
        self?.acceptConnectionLoop()
    }
}
```

- [ ] **Step 4: Send `.disconnected` in `stop()`**

In `stop()` (line 867), add before the close:

```swift
override func stop() {
    #log(.info, "Stopping local socket server on port \(self.port, privacy: .public)")
    connectionStateCancellable?.cancel()
    connectionStateCancellable = nil
    underlyingConnection?.stop()
    if serverSocketFD >= 0 {
        close(serverSocketFD)
        serverSocketFD = -1
    }
    ownStateSubject.send(.disconnected(error: nil))
}
```

- [ ] **Step 5: Build to verify compilation**

Run: `swift build --package-path RuntimeViewerCore 2>&1 | head -20`
Expected: Build succeeds (or only unrelated warnings).

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeLocalSocketConnection.swift
git commit -m "feat: add ownStateSubject to RuntimeLocalSocketServerConnection for stable state across reconnections"
```

---

### Task 2: Add auto-reconnect and `pendingHandlers` to `RuntimeLocalSocketClientConnection`

This is the core change. The injected code in sandboxed apps uses `RuntimeLocalSocketClientConnection` (socket client, business server). When the host app restarts, the socket closes. The client must detect disconnection and periodically retry connecting to the same deterministic port. Message handlers must be preserved and replayed onto each new underlying connection.

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeLocalSocketConnection.swift:551-599`

- [ ] **Step 1: Add state, reconnection, and handler storage properties**

Replace the entire `RuntimeLocalSocketClientConnection` class (lines 551-599) with the reconnection-capable version. The key additions are: `ownStateSubject` for stable state, `pendingHandlers` for handler replay, `connectionStateCancellable` for state observation, and a reconnection loop.

```swift
final class RuntimeLocalSocketClientConnection: RuntimeConnectionBase<RuntimeLocalSocketConnection>, @unchecked Sendable {
    private let identifier: String
    private let port: UInt16

    /// Stable state subject that bridges state across reconnections.
    private let ownStateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    /// Pending message handlers to apply to new connections.
    private var pendingHandlers: [@Sendable (RuntimeLocalSocketConnection) -> Void] = []

    /// Subscription for observing connection state changes.
    private var connectionStateCancellable: AnyCancellable?

    /// Whether this connection has been explicitly stopped.
    private var isStopped = false

    /// Retry interval for reconnection attempts (in nanoseconds).
    private static let reconnectInterval: UInt64 = 500_000_000 // 500ms

    /// Maximum time to wait for initial connection (seconds).
    private static let initialConnectionTimeout: TimeInterval = 10

    override var statePublisher: AnyPublisher<RuntimeConnectionState, Never> {
        ownStateSubject.eraseToAnyPublisher()
    }

    override var state: RuntimeConnectionState {
        ownStateSubject.value
    }

    /// Creates a client connection using deterministic port calculation.
    ///
    /// - Parameters:
    ///   - identifier: Unique identifier matching the server's identifier.
    ///   - timeout: Maximum time to wait for server to be ready (default: 10 seconds).
    /// - Throws: `RuntimeLocalSocketError` if connection cannot be established.
    init(identifier: String, timeout: TimeInterval = 10) async throws {
        self.identifier = identifier
        self.port = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)
        super.init()

        // Retry connection until server is ready or timeout
        let startTime = Date()
        var lastError: Error?

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let connection = try RuntimeLocalSocketConnection(port: port)
                self.underlyingConnection = connection
                applyPendingHandlers(to: connection)
                observeConnectionState(connection)
                try connection.start()
                ownStateSubject.send(.connected)
                return
            } catch {
                lastError = error
                // Wait before retry
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        throw lastError ?? RuntimeLocalSocketError.connectFailed(errno: ETIMEDOUT, port: port)
    }

    /// Creates a client connection to a known port.
    ///
    /// - Parameters:
    ///   - port: The server port to connect to.
    /// - Throws: `RuntimeLocalSocketError` if connection cannot be established.
    init(port: UInt16) throws {
        self.identifier = ""
        self.port = port
        super.init()

        let connection = try RuntimeLocalSocketConnection(port: port)
        self.underlyingConnection = connection
        observeConnectionState(connection)
        try connection.start()
        ownStateSubject.send(.connected)
    }

    // MARK: - Message Handler Overrides

    override func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (_: NullPayload) in
                try await handler()
                return NullPayload.null
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Request>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) where Request: Codable {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (request: Request) in
                try await handler(request)
                return NullPayload.null
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Response>(name: String, handler: @escaping @Sendable () async throws -> Response) where Response: Codable {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (_: NullPayload) in
                return try await handler()
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Request>(requestType: Request.Type, handler: @escaping @Sendable (Request) async throws -> Request.Response) where Request: RuntimeRequest {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler { @Sendable (request: Request) in
                return try await handler(request)
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Request, Response>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) where Request: Codable, Response: Codable {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (request: Request) in
                return try await handler(request)
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    // MARK: - Connection Lifecycle

    /// Applies all pending handlers to a connection.
    private func applyPendingHandlers(to connection: RuntimeLocalSocketConnection) {
        for handler in pendingHandlers {
            handler(connection)
        }
    }

    /// Observes the underlying connection state and triggers reconnection on disconnect.
    private func observeConnectionState(_ connection: RuntimeLocalSocketConnection) {
        connectionStateCancellable = connection.statePublisher
            .sink { [weak self] state in
                guard let self, !isStopped else { return }
                if state.isDisconnected {
                    ownStateSubject.send(state)
                    startReconnecting()
                }
            }
    }

    /// Starts the reconnection loop in the background.
    private func startReconnecting() {
        guard !isStopped else { return }
        ownStateSubject.send(.connecting)
        Task { [weak self] in
            await self?.reconnectionLoop()
        }
    }

    /// Periodically attempts to reconnect to the same port until successful or stopped.
    private func reconnectionLoop() async {
        while !isStopped {
            do {
                try await Task.sleep(nanoseconds: Self.reconnectInterval)
            } catch {
                return // Task cancelled
            }

            guard !isStopped else { return }

            do {
                let newConnection = try RuntimeLocalSocketConnection(port: port)
                self.underlyingConnection = newConnection
                applyPendingHandlers(to: newConnection)
                observeConnectionState(newConnection)
                try newConnection.start()
                ownStateSubject.send(.connected)
                return // Reconnected successfully
            } catch {
                // Retry on next iteration
                continue
            }
        }
    }

    override func stop() {
        isStopped = true
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        underlyingConnection?.stop()
        ownStateSubject.send(.disconnected(error: nil))
    }

    deinit {
        stop()
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build --package-path RuntimeViewerCore 2>&1 | head -20`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeLocalSocketConnection.swift
git commit -m "feat: add auto-reconnect and pendingHandlers to RuntimeLocalSocketClientConnection"
```

---

### Task 3: Add socket injection record persistence to `RuntimeEngineManager`

When the host app injects into a sandboxed app, persist `{pid, appName}` to a JSON file so that on restart the host can discover which sandboxed processes are still alive and reconnect.

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift`

- [ ] **Step 1: Add the `InjectedSocketEndpointRecord` struct and persistence methods**

Add inside `RuntimeEngineManager`, after the existing properties (after line 62):

```swift
// MARK: - Socket Injection Persistence

private struct InjectedSocketEndpointRecord: Codable {
    let pid: pid_t
    let appName: String
}

private static var injectedSocketEndpointsFileURL: URL {
    let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let runtimeViewerDirectory = applicationSupportURL.appendingPathComponent("RuntimeViewer")
    try? FileManager.default.createDirectory(at: runtimeViewerDirectory, withIntermediateDirectories: true)
    return runtimeViewerDirectory.appendingPathComponent("injected-socket-endpoints.json")
}

private func loadInjectedSocketEndpointRecords() -> [InjectedSocketEndpointRecord] {
    let fileURL = Self.injectedSocketEndpointsFileURL
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([InjectedSocketEndpointRecord].self, from: data)) ?? []
}

private func saveInjectedSocketEndpointRecords(_ records: [InjectedSocketEndpointRecord]) {
    let fileURL = Self.injectedSocketEndpointsFileURL
    guard let data = try? JSONEncoder().encode(records) else { return }
    try? data.write(to: fileURL, options: [.atomic])
}

private func addInjectedSocketEndpointRecord(pid: pid_t, appName: String) {
    var records = loadInjectedSocketEndpointRecords()
    records.removeAll { $0.pid == pid }
    records.append(InjectedSocketEndpointRecord(pid: pid, appName: appName))
    saveInjectedSocketEndpointRecords(records)
}

private func removeInjectedSocketEndpointRecord(pid: pid_t) {
    var records = loadInjectedSocketEndpointRecords()
    records.removeAll { $0.pid == pid }
    saveInjectedSocketEndpointRecords(records)
}
```

- [ ] **Step 2: Persist record when launching a sandboxed attached engine**

In `launchAttachedRuntimeEngine(name:identifier:isSandbox:)` (line 216), add after `attachedRuntimeEngines.append(runtimeEngine)` (line 227):

```swift
if isSandbox, let pid = Int32(identifier) {
    addInjectedSocketEndpointRecord(pid: pid, appName: name)
}
```

- [ ] **Step 3: Remove record on engine termination**

In `terminateRuntimeEngine(for:)` (line 316), add before `rebuildSections()`:

```swift
if case .localSocket(_, let socketIdentifier, .client) = source, let pid = Int32(socketIdentifier.rawValue) {
    removeInjectedSocketEndpointRecord(pid: pid)
}
```

- [ ] **Step 4: Build to verify compilation**

Build the main app scheme:

```bash
xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -5
```

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift
git commit -m "feat: persist socket injection records for reconnection on host restart"
```

---

### Task 4: Reconnect socket injected endpoints on startup

On startup, read the persisted records, check which processes are still alive, and create socket server engines for them. The injected client's auto-reconnect loop will connect to these servers.

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift`

- [ ] **Step 1: Add `reconnectInjectedSocketEngines()` method**

Add after `reconnectInjectedEngines()` (after line 268):

```swift
/// Reconnects to already-injected sandboxed apps by reading persisted
/// socket endpoint records and recreating socket servers.
private func reconnectInjectedSocketEngines() async {
    let records = loadInjectedSocketEndpointRecords()
    guard !records.isEmpty else {
        #log(.info, "No injected socket endpoints to reconnect")
        return
    }
    #log(.info, "Found \(records.count) injected socket endpoint(s) to reconnect")

    var aliveRecords: [InjectedSocketEndpointRecord] = []

    for record in records {
        // Check if the process is still alive
        guard kill(record.pid, 0) == 0 else {
            #log(.info, "Injected socket endpoint PID \(record.pid) is no longer alive, removing record")
            continue
        }

        do {
            let runtimeEngine = RuntimeEngine(
                source: .localSocket(
                    name: record.appName,
                    identifier: .init(rawValue: "\(record.pid)"),
                    role: .client
                )
            )
            try await runtimeEngine.connect()
            #log(.info, "Reconnected to injected sandboxed app: \(record.appName, privacy: .public) (PID: \(record.pid))")
            attachedRuntimeEngines.append(runtimeEngine)
            observeRuntimeEngineState(runtimeEngine)
            cacheLocalAppIcon(for: runtimeEngine, processIdentifier: "\(record.pid)")
            aliveRecords.append(record)
        } catch {
            #log(.error, "Failed to reconnect to injected sandboxed app \(record.appName, privacy: .public) (PID: \(record.pid)): \(error, privacy: .public)")
        }
    }

    // Update the persisted records to only contain alive entries
    saveInjectedSocketEndpointRecords(aliveRecords)

    if !aliveRecords.isEmpty {
        rebuildSections()
    }
}
```

- [ ] **Step 2: Call from `launchSystemRuntimeEngines()`**

In `launchSystemRuntimeEngines()` (line 198), add after the `reconnectInjectedEngines()` call (line 213):

```swift
await reconnectInjectedSocketEngines()
```

- [ ] **Step 3: Build to verify compilation**

```bash
xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -5
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift
git commit -m "feat: reconnect socket injected endpoints on host app startup"
```

---

### Task 5: Full build verification

- [ ] **Step 1: Build RuntimeViewerCore package**

```bash
swift build --package-path RuntimeViewerCore 2>&1 | tail -5
```

Expected: Build succeeds.

- [ ] **Step 2: Build main app**

```bash
xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -5
```

Expected: Build succeeds.

- [ ] **Step 3: Verify the reconnection flow manually**

1. Launch RuntimeViewer
2. Inject into a sandboxed app → verify connection established
3. Quit RuntimeViewer
4. Verify `~/Library/Application Support/RuntimeViewer/injected-socket-endpoints.json` contains the record
5. Relaunch RuntimeViewer → verify socket server is recreated and injected client reconnects
6. Kill the sandboxed app → verify record is cleaned up on next launch
