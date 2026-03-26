# Injected Endpoint Reconnection Design

## Problem

When the Host app injects code into a non-sandboxed target app via XPC, and then the Host exits, the injected app continues running but the connection is lost. When the Host restarts, it has no way to discover or reconnect to these already-injected apps.

## Scope

- **In scope:** Non-sandboxed apps using XPC connections (`.remote` source type)
- **Out of scope:** Sandboxed apps (need entitlement for Mach Service access), iOS/Bonjour connections

## Solution Overview

Use the existing Mach Service (privileged helper daemon, persists across Host restarts) as a registry for injected app XPC endpoints. The injected app registers its XPC listener endpoint after initial connection succeeds. When the Host restarts, it queries the Mach Service for all registered endpoints and reconnects directly — reusing the injected app's existing XPC listener (no new listener creation or engine recreation needed).

## Architecture

```
Initial Injection (existing flow unchanged):
  Host ──handshake──► Mach Service ◄──handshake── Injected App
  Host ◄═══════════ bidirectional XPC ═══════════► Injected App

After Connection Established (new):
  Injected App ──RegisterInjectedEndpoint──► Mach Service
  Mach Service starts monitoring PID via DispatchSource

Host Exits → Restarts (new):
  Host ──FetchAllInjectedEndpoints──► Mach Service
  Host ◄── [InjectedEndpointInfo] ──┘
  Host ──connect to endpoint──► Injected App (reused listener)
  Host ──ClientReconnected(clientEP)──► Injected App
  Injected App updates self.connection, re-pushes data
  Host ◄═══════════ bidirectional XPC ═══════════► Injected App
```

## Detailed Design

### 1. Data Types (`RuntimeRequestResponse.swift`)

New types for the injected endpoint registry, separate from the existing `RegisterEndpointRequest` / `FetchEndpointRequest` (which are used for 1-to-1 XPC endpoint brokering between Host and Mac Catalyst Helper):

```swift
struct InjectedEndpointInfo: Codable {
    let pid: pid_t
    let appName: String
    let bundleIdentifier: String
    let endpoint: XPCEndpoint
}

struct RegisterInjectedEndpointRequest: RuntimeRequest {
    // Fields: pid, appName, bundleIdentifier, endpoint
    // Response: VoidResponse
}

struct FetchAllInjectedEndpointsRequest: RuntimeRequest {
    // No fields
    // Response: Response([InjectedEndpointInfo])
}

struct RemoveInjectedEndpointRequest: RuntimeRequest {
    // Fields: pid
    // Response: VoidResponse
}
```

### 2. Mach Service (`RuntimeViewerService.swift`)

New storage and handlers, completely separate from the existing `endpointByIdentifier` dictionary:

```
New properties:
  injectedEndpoints: [pid_t: InjectedEndpointInfo]
  processMonitorSources: [pid_t: DispatchSourceProcess]

New handlers:
  registerInjectedEndpoint(request):
    1. Store in injectedEndpoints[request.pid]
    2. Create DispatchSource.makeProcessSource(identifier: request.pid, eventMask: .exit)
    3. On process exit: remove injectedEndpoints[pid], cancel source

  fetchAllInjectedEndpoints(request):
    Return Array(injectedEndpoints.values)

  removeInjectedEndpoint(request):
    Remove injectedEndpoints[request.pid], cancel corresponding source
```

### 3. XPC Connection Layer (`RuntimeXPCConnection.swift`)

#### Server Side — Reconnection Handler

`RuntimeXPCServerConnection` registers a `ClientReconnected` handler on its listener during `init`:

```
Handler receives: new client's listener endpoint (XPCEndpoint)
  1. Create XPCConnection to new client's endpoint
  2. Activate + Ping to verify
  3. Replace self.connection = newConnection
  4. Register errorHandler (same as existing logic)
  5. stateSubject.send(.connected)
```

This handler is always registered but only fires when a reconnecting Host sends the `ClientReconnected` command. During normal operation it is never triggered.

#### Client Side — Direct Connect Init

New `RuntimeXPCClientConnection.init(identifier:serverEndpoint:)` for reconnection:

```
  1. Call super.init (creates anonymous listener + connects to Mach Service)
  2. Create XPCConnection to serverEndpoint
  3. Activate + Ping to verify
  4. Send "ClientReconnected" command with payload = self.listener.endpoint
  5. self.connection = serverConnection
  6. stateSubject.send(.connected)
```

After setup, the connection state is identical to a normal post-handshake connection:

```
Client (new Host)                              Server (injected app, reused listener)
┌──────────────────────┐                ┌──────────────────────┐
│ listener (handlers)  │◄───── new ─────│ self.connection (upd) │  Server → Client push
│                      │                │                       │
│ self.connection (new)│───── new ─────►│ listener (original)   │  Client → Server request
│                      │                │  (all handlers alive)  │
└──────────────────────┘                └───────────────────────┘
```

#### Engine Data Re-push

When `RuntimeEngine` detects the connection state transitions back to `.connected` (after having been `.disconnected`), it re-pushes the current `imageList`, `imageNodes`, and `reloadData` to the new Client, since the Client relies on push-based updates.

### 4. Exposing Listener Endpoint

The `RuntimeConnection` protocol currently does not expose the listener's XPC endpoint. To allow `RuntimeViewerServer` to register the endpoint with the Mach Service after connection:

- Add an optional property to `RuntimeConnection` (or specifically to `RuntimeXPCServerConnection`) that exposes the `XPCEndpoint` of the listener
- `RuntimeEngine` exposes this through a property so `RuntimeViewerServer` can access it after `connect()` succeeds

### 5. Injected App (`RuntimeViewerServer.swift`)

After existing `connect()` succeeds, add:

```
  1. Get listener endpoint from runtimeEngine (via new property)
  2. Connect to Mach Service
  3. Send RegisterInjectedEndpointRequest(
       pid: ProcessInfo.processInfo.processIdentifier,
       appName: processName,
       bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
       endpoint: listenerEndpoint
     )
```

Registration happens immediately after initial connection — not deferred until disconnect. This ensures the endpoint is available even if the Host crashes unexpectedly.

### 6. RuntimeSource & RuntimeCommunicator

**`RuntimeSource.swift`** — new case:

```swift
case injectedRemote(name: String, identifier: Identifier, endpoint: XPCEndpoint)
```

**`RuntimeCommunicator.swift`** — handle new case:

```
case .injectedRemote(_, let identifier, let endpoint):
    return RuntimeXPCClientConnection(identifier: identifier, serverEndpoint: endpoint)
```

### 7. Host App (`RuntimeEngineManager.swift`)

New method `reconnectInjectedEngines()`, called during `launchSystemRuntimeEngines()`:

```
reconnectInjectedEngines():
  1. Send FetchAllInjectedEndpointsRequest via RuntimeInjectClient
  2. For each InjectedEndpointInfo:
     - Create RuntimeEngine(source: .injectedRemote(
         name: info.appName,
         identifier: .init(rawValue: "\(info.pid)"),
         endpoint: info.endpoint
       ))
     - try await engine.connect()
     - On failure: send RemoveInjectedEndpointRequest(pid: info.pid) to clean up
     - On success: append to attachedRuntimeEngines,
                   call observeRuntimeEngineState(engine),
                   call cacheLocalAppIcon(for:processIdentifier:),
                   call rebuildSections()
```

## Scenarios

### Scenario 1: Normal Injection → Host Exit → Host Restart

```
T1  Host injects App → normal handshake → connected
T2  Injected App registers (pid, name, bundleId, endpoint) with Mach Service
    Mach Service starts monitoring PID
T3  Host exits → Server connection error → engine state = .disconnected
    (Injected App continues running, listener stays alive)
T4  Host restarts → reconnectInjectedEngines()
    → fetch all injected endpoints
    → create engine(.injectedRemote) → direct connect to server endpoint
    → send ClientReconnected(clientListener.endpoint)
    → Server updates connection, re-pushes data
    → both sides state = .connected
```

### Scenario 2: Injected App Exits

```
  Injected App exits → Mach Service DispatchSource fires
  → auto-remove injectedEndpoints[pid] + cancel source
  → Host's next query won't see this endpoint
```

### Scenario 3: Host Restarts After Injected App Already Exited

```
  Host restarts → fetchAllInjectedEndpoints → empty list (already cleaned up)
  → nothing to reconnect

  Or: PID monitoring delayed → stale endpoint returned → connection fails
  → Host sends RemoveInjectedEndpointRequest to clean up
```

## Files to Modify

| File | Change |
|------|--------|
| `RuntimeViewerCore/.../RuntimeRequestResponse.swift` | New request/response types, `InjectedEndpointInfo` |
| `RuntimeViewerCore/.../RuntimeSource.swift` | New `.injectedRemote` case |
| `RuntimeViewerCore/.../RuntimeCommunicator.swift` | Handle `.injectedRemote` |
| `RuntimeViewerCore/.../Connections/RuntimeXPCConnection.swift` | Server: `ClientReconnected` handler; Client: new `init(identifier:serverEndpoint:)` |
| `RuntimeViewerCore/.../RuntimeConnection.swift` | Expose optional listener endpoint property |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift` | Expose listener endpoint; re-push data on reconnection; update top-level architecture comment |
| `RuntimeViewerPackages/.../RuntimeViewerService/RuntimeViewerService.swift` | `injectedEndpoints` dict, PID monitoring, 3 new handlers, update top-level comment |
| `RuntimeViewerPackages/.../RuntimeViewerHelperClient/RuntimeInjectClient.swift` | New methods for injected endpoint requests |
| `RuntimeViewerServer/RuntimeViewerServer/RuntimeViewerServer.swift` | Register endpoint after connect |
| `RuntimeViewerUsingAppKit/.../Utils/RuntimeEngineManager.swift` | `reconnectInjectedEngines()` on startup |
