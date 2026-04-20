# Injected Endpoint Reconnection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the Host app to rediscover and reconnect to already-injected non-sandboxed apps after restart, using the Mach Service daemon as a persistent XPC endpoint registry.

**Architecture:** The injected app registers its XPC listener endpoint with the Mach Service after initial connection. The Mach Service monitors PIDs for auto-cleanup. On Host restart, `RuntimeEngineManager` fetches all registered endpoints and reconnects directly to each injected app's existing XPC listener, bypassing the normal handshake. The `ClientReconnected` command allows the server to update its peer connection to point to the new Host.

**Tech Stack:** SwiftyXPC, XPC Mach services, DispatchSource (process monitoring), Swift concurrency

**Design spec:** `Documentations/Plans/2026-03-26-injected-endpoint-reconnection-design.md`

---

### Task 1: New Request/Response Types

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/InjectedEndpointInfo.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/RegisterInjectedEndpointRequest.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/FetchAllInjectedEndpointsRequest.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/RemoveInjectedEndpointRequest.swift`

- [ ] **Step 1: Create `InjectedEndpointInfo.swift`**

```swift
#if os(macOS)

import Foundation
public import SwiftyXPC

/// Metadata for an injected app's registered XPC endpoint.
///
/// Stored by the Mach Service daemon and returned to the Host app
/// for reconnecting to already-injected processes after restart.
public struct InjectedEndpointInfo: Codable, Sendable {
    /// The process identifier of the injected app.
    public let pid: pid_t

    /// The display name of the injected app.
    public let appName: String

    /// The bundle identifier of the injected app.
    public let bundleIdentifier: String

    /// The XPC listener endpoint of the injected app's runtime engine server.
    public let endpoint: SwiftyXPC.XPCEndpoint

    public init(pid: pid_t, appName: String, bundleIdentifier: String, endpoint: SwiftyXPC.XPCEndpoint) {
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.endpoint = endpoint
    }
}

#endif
```

- [ ] **Step 2: Create `RegisterInjectedEndpointRequest.swift`**

```swift
#if os(macOS)

import Foundation
public import SwiftyXPC

/// Registers an injected app's XPC endpoint with the Mach Service daemon.
///
/// Sent by the injected app after its initial XPC connection succeeds.
/// The daemon starts monitoring the PID and auto-removes the endpoint on process exit.
public struct RegisterInjectedEndpointRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.RegisterInjectedEndpoint"

    public typealias Response = VoidResponse

    public let pid: pid_t
    public let appName: String
    public let bundleIdentifier: String
    public let endpoint: SwiftyXPC.XPCEndpoint

    public init(pid: pid_t, appName: String, bundleIdentifier: String, endpoint: SwiftyXPC.XPCEndpoint) {
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.endpoint = endpoint
    }
}

#endif
```

- [ ] **Step 3: Create `FetchAllInjectedEndpointsRequest.swift`**

```swift
#if os(macOS)

import Foundation

/// Fetches all currently registered injected app endpoints from the Mach Service daemon.
///
/// Sent by the Host app on startup to discover already-injected processes for reconnection.
public struct FetchAllInjectedEndpointsRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.FetchAllInjectedEndpoints"

    public struct Response: RuntimeResponse, Codable {
        public let endpoints: [InjectedEndpointInfo]

        public init(endpoints: [InjectedEndpointInfo]) {
            self.endpoints = endpoints
        }
    }

    public init() {}
}

#endif
```

- [ ] **Step 4: Create `RemoveInjectedEndpointRequest.swift`**

```swift
#if os(macOS)

import Foundation

/// Removes an injected app's endpoint from the Mach Service daemon.
///
/// Sent by the Host app when a reconnection attempt fails, indicating
/// the injected process has likely exited (backup for PID monitoring).
public struct RemoveInjectedEndpointRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.RemoveInjectedEndpoint"

    public typealias Response = VoidResponse

    public let pid: pid_t

    public init(pid: pid_t) {
        self.pid = pid
    }
}

#endif
```

- [ ] **Step 5: Build to verify compilation**

Run: `swift build` in `RuntimeViewerCore/`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/InjectedEndpointInfo.swift \
        RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/RegisterInjectedEndpointRequest.swift \
        RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/FetchAllInjectedEndpointsRequest.swift \
        RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/RemoveInjectedEndpointRequest.swift
git commit -m "feat: add request/response types for injected endpoint registry"
```

---

### Task 2: XPC Connection — ClientReconnected Handler + Direct Connect Init + Endpoint Protocol

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeXPCConnection.swift`

- [ ] **Step 1: Add `XPCListenerEndpointProviding` protocol and `clientReconnected` command identifier**

Add the protocol **before** the `RuntimeXPCConnection` class (after the imports, before line 8):

```swift
/// Protocol for connections that expose their XPC listener endpoint.
///
/// Used by `RuntimeEngine` to retrieve the server's listener endpoint
/// for registration with the Mach Service injected endpoint registry.
public protocol XPCListenerEndpointProviding: AnyObject {
    var xpcListenerEndpoint: SwiftyXPC.XPCEndpoint { get }
}
```

Add conformance on `RuntimeXPCConnection` after the class definition (after line 200, before the `CommandIdentifiers` enum):

```swift
extension RuntimeXPCConnection: XPCListenerEndpointProviding {
    public var xpcListenerEndpoint: SwiftyXPC.XPCEndpoint { listener.endpoint }
}
```

Add the new command identifier to `CommandIdentifiers` enum (after line 205):

```swift
static let clientReconnected = command("ClientReconnected")
```

- [ ] **Step 2: Add `ClientReconnected` handler to `RuntimeXPCServerConnection`**

Update the `RuntimeXPCServerConnection` doc comment (replace lines 261-288) to document reconnection support:

```swift
// MARK: - RuntimeXPCServerConnection

/// XPC server connection for the service provider side.
///
/// Use this in a separate process (such as injected code in a target app or
/// Mac Catalyst helper) that provides runtime inspection services to the main application.
///
/// ## Initialization Flow
///
/// 1. Connects to the XPC Mach service (privileged helper)
/// 2. Fetches the client's endpoint from the broker
/// 3. Establishes direct connection to the client
/// 4. Registers its own endpoint for bidirectional communication
/// 5. Notifies the client via `serverLaunched` message
///
/// ## Reconnection Support
///
/// After the initial connection, a `ClientReconnected` handler is registered on the
/// listener. When the Host app restarts and reconnects (via direct endpoint), it sends
/// `ClientReconnected` with its new listener endpoint. The server replaces its peer
/// connection and transitions back to `.connected` state, enabling the engine to
/// re-push runtime data to the new client.
```

Add the `ClientReconnected` handler at the end of `RuntimeXPCServerConnection.init`, after `stateSubject.send(.connected)` (after line 307, before the closing `}`):

```swift
        // Register reconnection handler for when the Host app restarts and reconnects
        // via the injected endpoint registry (bypassing the normal handshake).
        listener.setMessageHandler(name: CommandIdentifiers.clientReconnected) { [weak self] (_: XPCConnection, clientEndpoint: SwiftyXPC.XPCEndpoint) in
            guard let self else { return }
            #log(.info, "XPC server received ClientReconnected, establishing new connection to client...")
            let newConnection = try XPCConnection(type: .remoteServiceFromEndpoint(clientEndpoint))
            newConnection.activate()
            newConnection.errorHandler = { [weak self] in
                guard let self else { return }
                handleClientOrServerConnectionError(connection: $0, error: $1)
            }
            _ = try await newConnection.sendMessage(request: PingRequest())
            self.connection = newConnection
            self.stateSubject.send(.connected)
            #log(.info, "XPC server reconnected to new client successfully (ping OK)")
        }
```

- [ ] **Step 3: Add direct-connect init to `RuntimeXPCClientConnection`**

Add a new initializer to `RuntimeXPCClientConnection` (after the existing `override init`, before the closing `}`):

```swift
    /// Creates a client connection by directly connecting to a known server endpoint.
    ///
    /// Used for reconnecting to an already-injected app whose endpoint was retrieved
    /// from the Mach Service injected endpoint registry. Bypasses the normal handshake
    /// (no `RegisterEndpointRequest` / `serverLaunched` exchange).
    ///
    /// - Parameters:
    ///   - identifier: The runtime source identifier (typically the injected app's PID string).
    ///   - serverEndpoint: The server's XPC listener endpoint from the injected endpoint registry.
    ///   - modifier: Optional closure to configure the connection before activation.
    init(identifier: RuntimeSource.Identifier, serverEndpoint: SwiftyXPC.XPCEndpoint, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        try await super.init(identifier: identifier, modifier: modifier)
        #log(.info, "XPC client direct-connecting to server endpoint for identifier: \(identifier.rawValue, privacy: .public)")
        let serverConnection = try XPCConnection(type: .remoteServiceFromEndpoint(serverEndpoint))
        serverConnection.activate()
        serverConnection.errorHandler = { [weak self] in
            guard let self else { return }
            handleClientOrServerConnectionError(connection: $0, error: $1)
        }
        _ = try await serverConnection.sendMessage(request: PingRequest())
        #log(.info, "XPC client sending ClientReconnected to server with own listener endpoint...")
        try await serverConnection.sendMessage(name: CommandIdentifiers.clientReconnected, request: listener.endpoint)
        self.connection = serverConnection
        stateSubject.send(.connected)
        #log(.info, "XPC client direct-connected to server successfully")
    }
```

- [ ] **Step 4: Update the top-level architecture diagram**

Update the `RuntimeXPCConnection` class doc comment (lines 8-54) to include the reconnection flow. Replace the architecture diagram section:

```swift
/// ## Architecture
///
/// ### Initial Connection (Handshake via Mach Service Broker)
///
/// ```
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  Client App         │                    │  XPC Mach Service   │
/// │                     │   1. register      │  (Privileged Helper)│
/// │  XPCClientConnection│──────endpoint─────>│                     │
/// │                     │                    │  Endpoint Registry  │
/// └─────────────────────┘                    └─────────────────────┘
///                                                      │
///                                                      │ 2. broker
///                                                      ▼
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  Server Process     │  3. fetch endpoint │                     │
/// │  (e.g., Injected)   │<───────────────────┤                     │
/// │  XPCServerConnection│  4. direct XPC     │                     │
/// │                     │──────────────────->│  Client App         │
/// └─────────────────────┘  5. serverLaunched └─────────────────────┘
/// ```
///
/// ### Reconnection (Direct Endpoint via Injected Endpoint Registry)
///
/// ```
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  Client App (new)   │                    │  Server Process     │
/// │                     │  1. connect to     │  (already running)  │
/// │  XPCClientConnection│─────server EP─────>│  XPCServerConnection│
/// │  (serverEndpoint:)  │                    │  (reused listener)  │
/// │                     │  2. ClientRecon-   │                     │
/// │                     │─────nected(EP)────>│  3. update          │
/// │                     │                    │     self.connection  │
/// │                     │<═══bidirectional═══│                     │
/// └─────────────────────┘                    └─────────────────────┘
/// ```
```

- [ ] **Step 5: Build to verify compilation**

Run: `swift build` in `RuntimeViewerCore/`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeXPCConnection.swift
git commit -m "feat: add XPC reconnection support — ClientReconnected handler and direct-connect init"
```

---

### Task 3: Mach Service — Injected Endpoint Registry + PID Monitoring

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerService/RuntimeViewerService.swift`

- [ ] **Step 1: Add properties for injected endpoint storage and PID monitoring**

Add after the existing `endpointByIdentifier` property (after line 15):

```swift
    /// Registered endpoints from injected (non-sandboxed) apps, keyed by PID.
    /// Separate from `endpointByIdentifier` which handles 1-to-1 XPC brokering.
    private var injectedEndpointsByPID: [pid_t: InjectedEndpointInfo] = [:]

    /// Dispatch sources monitoring injected process PIDs for auto-cleanup on exit.
    private var processMonitorSources: [pid_t: any DispatchSourceProcess] = [:]
```

- [ ] **Step 2: Register new handlers in `init`**

Add after the existing `listener.setMessageHandler(handler: fileOperation)` line (after line 24):

```swift
        listener.setMessageHandler(handler: registerInjectedEndpoint)
        listener.setMessageHandler(handler: fetchAllInjectedEndpoints)
        listener.setMessageHandler(handler: removeInjectedEndpoint)
```

- [ ] **Step 3: Add handler implementations**

Add after the `injectApplication` method (after line 79):

```swift
    // MARK: - Injected Endpoint Registry

    private func registerInjectedEndpoint(_ connection: XPCConnection, request: RegisterInjectedEndpointRequest) async throws -> RegisterInjectedEndpointRequest.Response {
        let injectedEndpointInfo = InjectedEndpointInfo(
            pid: request.pid,
            appName: request.appName,
            bundleIdentifier: request.bundleIdentifier,
            endpoint: request.endpoint
        )
        injectedEndpointsByPID[request.pid] = injectedEndpointInfo
        startMonitoringProcess(pid: request.pid)
        #log(.info, "Registered injected endpoint for PID \(request.pid) (\(request.appName, privacy: .public))")
        return .empty
    }

    private func fetchAllInjectedEndpoints(_ connection: XPCConnection, request: FetchAllInjectedEndpointsRequest) async throws -> FetchAllInjectedEndpointsRequest.Response {
        let endpoints = Array(injectedEndpointsByPID.values)
        #log(.info, "Fetching all injected endpoints, count: \(endpoints.count)")
        return .init(endpoints: endpoints)
    }

    private func removeInjectedEndpoint(_ connection: XPCConnection, request: RemoveInjectedEndpointRequest) async throws -> RemoveInjectedEndpointRequest.Response {
        removeInjectedEndpointEntry(pid: request.pid)
        return .empty
    }

    private func startMonitoringProcess(pid: pid_t) {
        processMonitorSources[pid]?.cancel()

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            #log(.info, "Monitored process \(pid) exited, removing injected endpoint")
            removeInjectedEndpointEntry(pid: pid)
        }
        processMonitorSources[pid] = source
        source.resume()
    }

    private func removeInjectedEndpointEntry(pid: pid_t) {
        injectedEndpointsByPID.removeValue(forKey: pid)
        processMonitorSources[pid]?.cancel()
        processMonitorSources.removeValue(forKey: pid)
        #log(.info, "Removed injected endpoint for PID \(pid)")
    }
```

- [ ] **Step 4: Update the class-level comment**

Replace the `@Loggable` line and add a doc comment before the class (before line 9):

```swift
/// Privileged helper daemon running as a Mach service.
///
/// Handles:
/// - XPC endpoint brokering between Host app and Mac Catalyst helper
/// - Code injection via `MachInjector`
/// - Privileged file operations (installing `RuntimeViewerServer.framework`)
/// - Injected endpoint registry for Host app reconnection after restart
///   (stores endpoints keyed by PID, monitors PIDs via DispatchSource for auto-cleanup)
/// - Process lifecycle tracking (terminates child apps when caller exits)
```

- [ ] **Step 5: Build to verify compilation**

Run: `swift build` in `RuntimeViewerPackages/`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerService/RuntimeViewerService.swift
git commit -m "feat: add injected endpoint registry with PID monitoring to Mach Service"
```

---

### Task 4: RuntimeInjectClient — New Request Methods

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerHelperClient/RuntimeInjectClient.swift`

- [ ] **Step 1: Add methods for injected endpoint operations**

Add after the `installServerFramework()` method (after line 112, before the closing `}`):

```swift
    // MARK: - Injected Endpoint Registry

    /// Registers an injected app's XPC endpoint with the Mach Service daemon.
    public func registerInjectedEndpoint(pid: pid_t, appName: String, bundleIdentifier: String, endpoint: SwiftyXPC.XPCEndpoint) async throws {
        try await connectionIfNeeded().sendMessage(request: RegisterInjectedEndpointRequest(
            pid: pid,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            endpoint: endpoint
        ))
    }

    /// Fetches all registered injected app endpoints from the Mach Service daemon.
    public func fetchAllInjectedEndpoints() async throws -> [InjectedEndpointInfo] {
        let response: FetchAllInjectedEndpointsRequest.Response = try await connectionIfNeeded().sendMessage(request: FetchAllInjectedEndpointsRequest())
        return response.endpoints
    }

    /// Removes an injected app's endpoint from the Mach Service daemon.
    public func removeInjectedEndpoint(pid: pid_t) async throws {
        try await connectionIfNeeded().sendMessage(request: RemoveInjectedEndpointRequest(pid: pid))
    }
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build` in `RuntimeViewerPackages/`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerHelperClient/RuntimeInjectClient.swift
git commit -m "feat: add injected endpoint registry methods to RuntimeInjectClient"
```

---

### Task 5: RuntimeCommunicator + RuntimeEngine — XPC Endpoint Passthrough

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeCommunicator.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`

- [ ] **Step 1: Add `xpcServerEndpoint` parameter to `RuntimeCommunicator.connect()`**

Update the method signature (line 57) to add the parameter:

```swift
    public func connect(to source: RuntimeSource, bonjourEndpoint: RuntimeNetworkEndpoint? = nil, xpcServerEndpoint: Any? = nil, waitForConnection: Bool = true, modifier: ((RuntimeConnection) async throws -> Void)? = nil) async throws -> RuntimeConnection {
```

Update the `.remote` client case (lines 72-75) to check for the endpoint:

```swift
            } else {
                if let xpcServerEndpoint = xpcServerEndpoint as? SwiftyXPC.XPCEndpoint {
                    #log(.debug, "Creating XPC client connection (direct reconnect) with identifier: \(String(describing: identifier), privacy: .public)")
                    let connection = try await RuntimeXPCClientConnection(identifier: identifier, serverEndpoint: xpcServerEndpoint, modifier: modifier)
                    #log(.info, "XPC client direct reconnection established")
                    return connection
                } else {
                    #log(.debug, "Creating XPC client connection with identifier: \(String(describing: identifier), privacy: .public)")
                    let connection = try await RuntimeXPCClientConnection(identifier: identifier, modifier: modifier)
                    #log(.info, "XPC client connection established")
                    return connection
                }
            }
```

- [ ] **Step 2: Add `xpcServerEndpoint` parameter and `xpcListenerEndpoint` property to `RuntimeEngine`**

Add a stored property for the listener endpoint after the existing `connection` property (around line 151):

```swift
    /// The XPC listener endpoint of this engine's connection, if applicable.
    /// Set after `connect()` succeeds for XPC-based connections (macOS only).
    /// Used by injected apps to register their endpoint with the Mach Service
    /// for Host reconnection. Stored as `any Sendable` to avoid platform-specific
    /// types in the actor interface; cast to `SwiftyXPC.XPCEndpoint` on macOS.
    public private(set) var xpcListenerEndpoint: (any Sendable)?
```

Update the `connect()` method signature (line 173) to add the parameter:

```swift
    public func connect(bonjourEndpoint: RuntimeNetworkEndpoint? = nil, xpcServerEndpoint: Any? = nil) async throws {
```

In the `.server` branch of `connect()`, after the `communicator.connect` call succeeds (after line 184, `#log(.info, "Server connection established")`), add endpoint capture:

```swift
                if let xpcEndpointProvider = connection as? XPCListenerEndpointProviding {
                    xpcListenerEndpoint = xpcEndpointProvider.xpcListenerEndpoint
                }
```

> **Note — Data re-push is handled automatically.** The existing `needsReregistrationOnConnect` mechanism in `handleConnectionStateChange()` already covers the reconnection case: when the server's connection goes `.disconnected` → `.connected` (triggered by the `ClientReconnected` handler), the engine re-registers all message handlers and calls `observeRuntime()` which re-pushes `imageList`, `imageNodes`, and `reloadData` to the new client. No additional code is needed for data re-push.

In the `.client` branch of `connect()`, pass the endpoint through (update line 192):

```swift
                connection = try await communicator.connect(to: source, bonjourEndpoint: bonjourEndpoint, xpcServerEndpoint: xpcServerEndpoint) { connection in
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build` in `RuntimeViewerCore/`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeCommunicator.swift \
        RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
git commit -m "feat: add XPC endpoint passthrough for direct reconnection"
```

---

### Task 6: Injected App — Register Endpoint After Connect

**Files:**
- Modify: `RuntimeViewerServer/RuntimeViewerServer/RuntimeViewerServer.swift`

- [ ] **Step 1: Add endpoint registration after non-sandboxed XPC connect**

Replace the non-sandboxed branch (lines 55-57) with:

```swift
                } else {
                    runtimeEngine = RuntimeEngine(source: .remote(name: processName, identifier: .init(rawValue: identifier), role: .server))
                    try await runtimeEngine?.connect()

                    // Register the XPC listener endpoint with the Mach Service
                    // so the Host can reconnect after restart.
                    await registerInjectedEndpoint()
                }
```

- [ ] **Step 2: Add the `registerInjectedEndpoint` method**

Add after the `main()` method (after line 75, before the closing `}`):

```swift
    #if os(macOS)
    private static func registerInjectedEndpoint() async {
        guard let endpoint = await runtimeEngine?.xpcListenerEndpoint as? SwiftyXPC.XPCEndpoint else {
            #log(.error, "Failed to get XPC listener endpoint for registration")
            return
        }

        do {
            let connection = try XPCConnection(type: .remoteMachService(serviceName: RuntimeViewerMachServiceName, isPrivilegedHelperTool: true))
            connection.activate()
            try await connection.sendMessage(request: RegisterInjectedEndpointRequest(
                pid: ProcessInfo.processInfo.processIdentifier,
                appName: processName,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                endpoint: endpoint
            ))
            #log(.info, "Registered injected endpoint with Mach Service (PID: \(ProcessInfo.processInfo.processIdentifier))")
        } catch {
            #log(.error, "Failed to register injected endpoint: \(error, privacy: .public)")
        }
    }
    #endif
```

- [ ] **Step 3: Add `SwiftyXPC` import**

Add the import at the top of the file, inside the `#if os(macOS) || targetEnvironment(macCatalyst)` block (after line 8):

```swift
#if os(macOS)
import SwiftyXPC
#endif
```

Note: This is a separate `#if` from the existing `#if os(macOS) || targetEnvironment(macCatalyst)` for `LaunchServicesPrivate`, because `SwiftyXPC` is macOS-only (not macCatalyst).

- [ ] **Step 4: Verify the build compiles**

Build the RuntimeViewerServer target (it's a framework, build via Xcode scheme or the parent project).

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerServer/RuntimeViewerServer/RuntimeViewerServer.swift
git commit -m "feat: register XPC listener endpoint with Mach Service after injection"
```

---

### Task 7: RuntimeEngineManager — Reconnect Injected Engines on Startup

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift`

- [ ] **Step 1: Add `runtimeInjectClient` dependency**

Add after the existing `@Dependency(\.runtimeHelperClient)` property (around line 59):

```swift
    @Dependency(\.runtimeInjectClient) private var runtimeInjectClient
```

- [ ] **Step 2: Call `reconnectInjectedEngines()` from `launchSystemRuntimeEngines()`**

Add a call at the end of `launchSystemRuntimeEngines()`, after the Mac Catalyst section (after line 208, before the closing `}`):

```swift
        await reconnectInjectedEngines()
```

- [ ] **Step 3: Implement `reconnectInjectedEngines()`**

Add the method after `launchAttachedRuntimeEngine` (after line 226):

```swift
    /// Reconnects to already-injected non-sandboxed apps by fetching their
    /// registered XPC endpoints from the Mach Service daemon.
    private func reconnectInjectedEngines() async {
        do {
            let injectedEndpoints = try await runtimeInjectClient.fetchAllInjectedEndpoints()
            guard !injectedEndpoints.isEmpty else {
                #log(.info, "No injected endpoints to reconnect")
                return
            }
            #log(.info, "Found \(injectedEndpoints.count) injected endpoint(s) to reconnect")

            for injectedEndpointInfo in injectedEndpoints {
                do {
                    let runtimeEngine = RuntimeEngine(
                        source: .remote(
                            name: injectedEndpointInfo.appName,
                            identifier: .init(rawValue: "\(injectedEndpointInfo.pid)"),
                            role: .client
                        )
                    )
                    try await runtimeEngine.connect(xpcServerEndpoint: injectedEndpointInfo.endpoint)
                    #log(.info, "Reconnected to injected app: \(injectedEndpointInfo.appName, privacy: .public) (PID: \(injectedEndpointInfo.pid))")
                    attachedRuntimeEngines.append(runtimeEngine)
                    observeRuntimeEngineState(runtimeEngine)
                    cacheLocalAppIcon(for: runtimeEngine, processIdentifier: "\(injectedEndpointInfo.pid)")
                } catch {
                    #log(.error, "Failed to reconnect to injected app \(injectedEndpointInfo.appName, privacy: .public) (PID: \(injectedEndpointInfo.pid)): \(error, privacy: .public)")
                    // Clean up stale endpoint
                    try? await runtimeInjectClient.removeInjectedEndpoint(pid: injectedEndpointInfo.pid)
                }
            }
            rebuildSections()
        } catch {
            #log(.error, "Failed to fetch injected endpoints: \(error, privacy: .public)")
        }
    }
```

- [ ] **Step 4: Build the main app target to verify compilation**

Build via XcodeBuildMCP or `xcodebuild -scheme RuntimeViewerUsingAppKit -configuration Debug build`

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift
git commit -m "feat: reconnect to injected apps on startup via Mach Service endpoint registry"
```

---

### Task 8: Manual Integration Test

This feature involves Mach services, code injection, and cross-process XPC — it cannot be unit tested. Test manually:

- [ ] **Step 1: Build and run the Host app**

Build the `RuntimeViewerUsingAppKit` scheme in Debug mode.

- [ ] **Step 2: Inject into a non-sandboxed app**

Use the "Attach to Process" UI to inject into a non-sandboxed macOS app (e.g., Terminal, Finder, or a custom test app).

- [ ] **Step 3: Verify initial connection works**

Confirm the injected app appears in the toolbar engine list and runtime data is displayed correctly.

- [ ] **Step 4: Quit the Host app**

Quit RuntimeViewer. The injected app should remain running.

- [ ] **Step 5: Restart the Host app**

Launch RuntimeViewer again.

- [ ] **Step 6: Verify reconnection**

Check that:
- The previously-injected app automatically appears in the toolbar engine list
- Runtime data (classes, images) is displayed correctly
- The app icon is shown correctly in the toolbar

- [ ] **Step 7: Verify cleanup on injected app exit**

Quit the injected app. Restart the Host app. Verify no stale entries appear in the engine list.

- [ ] **Step 8: Commit final state**

If any fixes were needed during testing, commit them.
