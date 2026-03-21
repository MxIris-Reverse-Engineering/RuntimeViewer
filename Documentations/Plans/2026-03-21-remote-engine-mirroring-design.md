# Remote Engine Mirroring Design

## Overview

Enable macOS clients to mirror all RuntimeEngines from remote hosts discovered via Bonjour. When Host A connects to Host B, Host A receives the complete engine list from Host B (including engines Host B mirrored from Host C), with cycle detection via origin chain tracking. The UI groups engines by host using `NSMenuItem.sectionHeaderWithTitle`.

## Architecture

```
Host A (Local)                                Host B (Remote)
─────────────                                 ─────────────
RuntimeEngineManager                          RuntimeEngineManager
  │                                             │
  ├─ local engine                               ├─ local engine ←──────────┐
  ├─ attached engines                           ├─ attached engine X ←─────┤
  │                                             ├─ bonjour engine (from C)←┤
  │  Bonjour discovery                          │                          │
  │      │                                      │                          │
  │      ▼                                      │                          │
  ├─ bonjour engine (Host B) ══════════════════►├─ Bonjour Server          │
  │   (management + Host B local data)          │   (mgmt + local data)    │
  │                                             │                          │
  │  Protocol: engineList command               │                          │
  │  ◄── engine list + directTCP ports ─────────┘                          │
  │                                             │                          │
  ├─ directTCP engine (X) ═════════════════════╪══► Proxy Server (X) ──────┘
  ├─ directTCP engine (C) ═════════════════════╪══► Proxy Server (C) ──────┘
```

### Key Design Decisions

1. **Management connection = Bonjour connection**: The existing Bonjour client engine doubles as the management channel AND a usable engine for browsing the remote host's local runtime data.
2. **Data connections = directTCP**: Each shared remote engine gets its own directTCP connection. The management connection provides host:port info.
3. **Full transitive mirroring**: Engines mirrored from third-party hosts are also shared.
4. **Cycle prevention**: Each engine carries an `originChain` (list of Host IDs, appended at each hop). Receivers skip engines whose chain contains their own `localInstanceID`.
5. **Generic proxy**: `RuntimeEngineProxyServer` can proxy any engine regardless of its underlying connection type (local, XPC, Bonjour, directTCP), and forwards both request-response and server-push data.
6. **Name-based messaging**: All new commands use `RuntimeEngine.CommandNames` + name-based message handlers, consistent with existing engine communication patterns (NOT `RuntimeRequest` protocol).

## 1. Communication Protocol

### New Commands

All management commands are added to `RuntimeEngine.CommandNames` and use the existing name-based message handler mechanism (`connection.sendMessage(name:request:)` / `connection.setMessageHandler(name:handler:)`), consistent with all other engine commands (imageList, imageNodes, reloadData, etc.).

#### CommandNames Additions

```swift
extension RuntimeEngine {
    fileprivate enum CommandNames: String, CaseIterable {
        // ... existing cases ...
        case engineList           // Request/response: client asks for engine list
        case engineListChanged    // Push: server notifies engine list changes
    }
}
```

#### RemoteEngineDescriptor

Describes a single shareable engine. Used as the payload for both `engineList` response and `engineListChanged` push.

```swift
public struct RemoteEngineDescriptor: Codable, Hashable {
    let engineID: String              // Unique identifier for this engine
    let source: RuntimeSource         // Original source type (already Codable)
    let hostName: String              // Human-readable host name
    let originChain: [String]         // Host ID chain for cycle detection (appended at each hop)
    let directTCPHost: String         // Proxy server host IP
    let directTCPPort: UInt16         // Proxy server port
}
```

#### Management Flow (within RuntimeEngine)

**Server side** — In `setupMessageHandlerForServer()`, add handler for `engineList` command. The handler delegates to `RuntimeEngineManager` to build the descriptor list.

**Implementation note**: The existing `setMessageHandlerBinding` overloads require a `Request` parameter. For `engineList` (no request body, has response), add a new overload:

```swift
// New setMessageHandlerBinding overload (no request, has response):
private func setMessageHandlerBinding<Response: Codable>(
    forName name: CommandNames,
    perform: @escaping (isolated RuntimeEngine) async throws -> Response
) {
    guard let connection else { return }
    connection.setMessageHandler(name: name.commandName) { [weak self] () -> Response in
        guard let self else { throw RequestError.senderConnectionIsLose }
        return try await perform(self)
    }
}

// In setupMessageHandlerForServer(), add:
setMessageHandlerBinding(forName: .engineList) { engine -> [RemoteEngineDescriptor] in
    await RuntimeEngineManager.shared.buildEngineDescriptors()
}
```

**Server push** — When `RuntimeEngineManager` detects engine list changes, it pushes via a new public method on `RuntimeEngine`:

```swift
// RuntimeEngine public API addition:
public func pushEngineListChanged(_ descriptors: [RemoteEngineDescriptor]) async throws {
    guard let connection, source.remoteRole?.isServer == true else { return }
    try await connection.sendMessage(name: .engineListChanged, request: descriptors)
}

// In RuntimeEngineManager, on engine list change:
try await bonjourServerEngine.pushEngineListChanged(buildEngineDescriptors())
```

**Client side** — In `setupMessageHandlerForClient()`, add handler for `engineListChanged`:

```swift
// In RuntimeEngine.setupMessageHandlerForClient(), add:
setMessageHandlerBinding(forName: .engineListChanged) { engine, descriptors in
    await RuntimeEngineManager.shared.handleEngineListChanged(descriptors, from: engine)
}
```

**Note**: `RuntimeEngine.connection` is `private`. Management commands go through the engine's own message handler infrastructure or dedicated public methods (`requestEngineList()`, `pushEngineListChanged()`), so no external access to `connection` is needed.

### Bonjour Server Single-Client Constraint

The current `RuntimeNetworkServerConnection` supports only one client at a time (accepts one `NWConnection`, then cancels the listener). This design works within this constraint:

- Each Bonjour server engine serves one management client
- If multiple remote hosts discover this host, only one can connect at a time via Bonjour
- When the connected client disconnects, the server restarts listening for the next client
- This is acceptable for the initial implementation; multi-client support can be added later by refactoring `RuntimeNetworkServerConnection` to accept multiple connections

## 2. Proxy Server

### RuntimeEngineProxyServer

Location: `RuntimeViewerCore/Sources/RuntimeViewerCore/`

A new actor that wraps any `RuntimeEngine` and exposes it via a directTCP server connection. Incoming requests are forwarded to the underlying engine, and server-push data is relayed to the connected client.

```swift
public actor RuntimeEngineProxyServer {
    let engine: RuntimeEngine
    private let connection: RuntimeConnection  // directTCP server (port 0, auto-assigned)
    private var subscriptions: Set<AnyCancellable> = []

    init(engine: RuntimeEngine, identifier: String) async throws

    var port: UInt16 { get }
    var host: String { get }

    func stop()
}
```

**Request-response handlers**: Mirrors `RuntimeEngine.setupMessageHandlerForServer()`, but forwards to `engine` public API:

```swift
// Register handlers on the directTCP server connection:
connection.setMessageHandler(name: .isImageLoaded) { [engine] (path: String) -> Bool in
    try await engine.isImageLoaded(path: path)
}
connection.setMessageHandler(name: .runtimeObjectsInImage) { [engine] (image: String) -> [RuntimeObject] in
    try await engine.objects(in: image)
}
// ... same pattern for all RuntimeEngine public methods
```

**Server-push relay**: Subscribe to the source engine's Combine publishers and forward to the directTCP client.

**Implementation note**: `imageList` is currently `public private(set) var` (NOT `@Published`), while `imageNodes` is `@Published` and `reloadDataPublisher` is a `PassthroughSubject`. For the proxy relay:
- `imageNodes`: subscribe via `engine.$imageNodes`
- `reloadDataPublisher`: subscribe via `engine.reloadDataPublisher`
- `imageList`: since `sendRemoteDataIfNeeded()` already pushes `imageList` before `reloadData`, the proxy can fetch `engine.imageList` when relaying `reloadData`. Alternatively, make `imageList` `@Published` during implementation.

```swift
// Subscribe to source engine's data changes and relay:
engine.$imageNodes.sink { [connection] imageNodes in
    Task { try? await connection.sendMessage(name: .imageNodes, request: imageNodes) }
}.store(in: &subscriptions)

engine.reloadDataPublisher.sink { [weak engine, connection] in
    Task {
        guard let engine else { return }
        let imageList = await engine.imageList
        try? await connection.sendMessage(name: .imageList, request: imageList)
        try? await connection.sendMessage(name: .reloadData)
    }
}.store(in: &subscriptions)
```

**Cross-actor calls**: Since `RuntimeEngine` is an actor and all its public methods are `async`, and `setMessageHandler` handler closures are already `@Sendable () async throws -> ...`, cross-actor `await` calls work naturally with no special handling needed.

## 3. Remote Host — Engine Sharing Management

### RuntimeEngineManager Additions (Server Side)

```swift
// New properties
private var proxyServers: [String: RuntimeEngineProxyServer] = [:]  // engineID → proxy

// New methods
func startSharingEngines()
func stopSharingEngines()
func buildEngineDescriptors() -> [RemoteEngineDescriptor]
```

**`startSharingEngines()`**:
- Observes `runtimeEngines` changes (via existing `@Published` / Rx binding)
- For each engine (except the Bonjour server engine itself), starts a `RuntimeEngineProxyServer`
- On engine list change: updates proxy servers + pushes `engineListChanged` command via Bonjour server engine's connection to the management client

**Origin chain construction**:
- Local engines: `originChain = [localInstanceID]`
- Mirrored engines: `originChain = remote engine's originChain + [localInstanceID]`
  (Each intermediate host appends its own ID, enabling full cycle detection across N hops)

**Proxy server cleanup**:
- When a proxied engine disconnects (e.g. attached process exits), the corresponding `RuntimeEngineProxyServer` is stopped, its TCP listener cancelled, and port released
- Push updated engine list to management client

## 4. Local Host — Engine Mirror Reception

### RuntimeEngineManager Additions (Client Side)

```swift
// New properties
private var mirroredEngines: [String: RuntimeEngine] = [:]  // engineID → engine

// New methods
func requestEngineList(from engine: RuntimeEngine)
func handleEngineListChanged(_ descriptors: [RemoteEngineDescriptor], from engine: RuntimeEngine)
```

**Flow after Bonjour client engine connects**:
1. Send `engineList` command via the Bonjour client engine, receive `[RemoteEngineDescriptor]`
2. `engineListChanged` handler is already registered by `setupMessageHandlerForClient()`
3. For each `RemoteEngineDescriptor`:
   a. **Cycle check**: Skip if `originChain` contains `RuntimeNetworkBonjour.localInstanceID`
   b. **Dedup check**: Skip if `engineID` already exists in any engine collection
   c. Create `RuntimeEngine(source: .directTCP(name:host:port:role: .client))` with `hostInfo` and `originChain` from descriptor
   d. Connect and store in `mirroredEngines`
4. On `engineListChanged` push: diff against current `mirroredEngines`, add/remove accordingly

**Initial engine list request**: After Bonjour client engine state becomes `.connected`, `RuntimeEngineManager` sends `engineList` command. This requires exposing a public method on `RuntimeEngine` to send the engine list request:

```swift
// RuntimeEngine public API addition (uses existing request(local:remote:) pattern):
public func requestEngineList() async throws -> [RemoteEngineDescriptor] {
    try await request {
        []  // Local engines don't have a remote engine list
    } remote: {
        try await $0.sendMessage(name: .engineList)
    }
}
```

## 5. Engine Identity Enhancement

### HostInfo

Location: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/` (co-located with networking types)

```swift
public struct HostInfo: Codable, Hashable, Sendable {
    public let hostID: String      // RuntimeNetworkBonjour.localInstanceID
    public let hostName: String    // SCDynamicStoreCopyComputerName / UIDevice.name
}
```

### RuntimeEngine Additions

```swift
public actor RuntimeEngine {
    // Existing properties...
    public nonisolated let hostInfo: HostInfo
    public nonisolated let originChain: [String]
}
```

- Local engines: `hostInfo = .local` (hostID = localInstanceID, hostName = computerName), `originChain = [localInstanceID]`
- Bonjour client engines: `hostInfo` from Bonjour TXT record (add `rv-host-name` key)
- Mirrored engines: constructed from `RemoteEngineDescriptor`

### Bonjour TXT Record Enhancement

Add `rv-host-name` to the Bonjour TXT record alongside existing `rv-instance-id`:

```swift
// In RuntimeNetworkBonjour.makeService(name:):
txtRecord["rv-instance-id"] = localInstanceID
txtRecord["rv-host-name"] = hostName  // NEW
```

## 6. UI — Toolbar Source Menu Grouping

### Data Model

```swift
public struct RuntimeEngineSection {
    public let hostName: String
    public let hostID: String
    public let engines: [RuntimeEngine]
}
```

`RuntimeEngineManager` provides `@Published var runtimeEngineSections: [RuntimeEngineSection]`, computed from all engines grouped by `hostInfo.hostID`. Exposed via Rx as `rx.runtimeEngineSections: Driver<[RuntimeEngineSection]>`.

### RxAppKit Extension (Local Dependency)

Add `sectionItems` binding directly in the RxAppKit library source:

```swift
extension Reactive where Base: NSPopUpButton {
    func sectionItems<Section, Item>(
        _ sections: Driver<[Section]>,
        sectionTitle: @escaping (Section) -> String,
        items: @escaping (Section) -> [Item],
        itemTitle: @escaping (Item) -> String,
        itemImage: ((Item) -> NSImage?)? = nil
    ) -> Disposable
}
```

**Behavior**:
1. On each `sections` emission: `removeAllItems()`
2. For each section:
   a. Add `NSMenuItem.sectionHeader(title:)` (disabled, non-selectable)
   b. For each item: add normal `NSMenuItem` with `representedObject` set to a stable identifier
3. Selection synchronization: use `representedObject` matching (not index-based)

### Selection Model Change

The current `switchSource: Signal<Int>` (index-based) will not work with section headers in the menu. Change to identifier-based selection:

```swift
// MainViewModel.Input — change:
// Before: let switchSource: Signal<Int>
// After:
let switchSource: Signal<String>  // engine identifier

// MainWindowController — change:
// Before: switchSourceItem.popUpButton.rx.selectedItemIndex()
// After:  switchSourceItem.popUpButton.rx.selectedItemRepresentedObject()
//         (new RxAppKit binding that emits representedObject of selected item)
```

Each `NSMenuItem` gets a stable engine identifier as `representedObject`. The `MainViewModel` matches this against `runtimeEngines` to find the selected engine.

**Implementation note**: `RuntimeSource.identifier` is currently `fileprivate` (defined in `RuntimeConnectionNotificationService.swift`). It needs to be promoted to a `public` property on `RuntimeSource` (move from `fileprivate` extension to the main `RuntimeSource` definition or a public extension).

### Menu Appearance

```
┌──────────────────────────┐
│ 本机                      │  ← sectionHeader (disabled)
│   Local Runtime           │
│   Attached: Safari        │
│ MacBook-Pro               │  ← sectionHeader (disabled)
│   Local Runtime           │
│   Attached: Xcode         │
│   iPhone 15 (via Host-C)  │
└──────────────────────────┘
```

## 7. Lifecycle Management

### Management Connection Disconnect

When a Bonjour management connection to a remote host disconnects:
1. Remove all mirrored engines from that host (`mirroredEngines` entries matching the host)
2. DirectTCP connections naturally close as mirrored engines are terminated
3. **Send `UserNotification`** via existing `RuntimeConnectionNotificationService.notifyDisconnected(source:error:)` — reuse the existing notification infrastructure (supports `Settings.shared.notifications` toggle)

### Remote Engine Change

On `engineListChanged` push:
1. Diff current `mirroredEngines` against new descriptor list
2. **Added**: Create directTCP client engine, connect
3. **Removed**: Terminate engine, close connection, clean up proxy server resources
4. **Unchanged**: Keep existing connection

### Proxy Server Cleanup

When a proxied engine disconnects on the server side:
1. Stop the `RuntimeEngineProxyServer` (cancel TCP listener, release port)
2. Remove from `proxyServers` dictionary
3. Push updated `engineListChanged` to management client

### UserNotification

Reuse existing `RuntimeConnectionNotificationService` (already supports connect/disconnect notifications with `UNUserNotificationCenter`, configurable via `Settings.shared.notifications`):

- Remote host disconnected: `notifyDisconnected(source:error:)` — already implemented
- Remote host connected: `notifyConnected(source:)` — already implemented
- Mirrored engine added/removed: extend `RuntimeConnectionNotificationService` with new methods if needed

## 8. Files to Create/Modify

### New Files
- `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RemoteEngineDescriptor.swift` — `RemoteEngineDescriptor`
- `RuntimeViewerCore/Sources/RuntimeViewerCommunication/HostInfo.swift` — `HostInfo`
- `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift` — Proxy server actor
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineSection.swift` — `RuntimeEngineSection`

### Modified Files
- `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`:
  - Add `hostInfo`, `originChain` nonisolated properties
  - Add `engineList`, `engineListChanged` to `CommandNames`
  - Add handlers in `setupMessageHandlerForServer/Client()`
  - Add `requestEngineList()` and `pushEngineListChanged()` public methods
  - Add new `setMessageHandlerBinding` overload (no request, has response)
- `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeSource.swift`:
  - Promote `identifier` from `fileprivate` to `public`
- `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeNetwork.swift`:
  - Add `rv-host-name` to Bonjour TXT record
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift`:
  - Add `proxyServers`, `mirroredEngines`, `runtimeEngineSections`
  - Add sharing management, mirror reception, proxy server lifecycle
  - Reuse `RuntimeConnectionNotificationService` for notifications
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift`:
  - Switch to section-based source binding
  - Change `switchSource` from `Signal<Int>` to `Signal<String>` (identifier-based)
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift`:
  - Update popup binding to use `sectionItems` and `representedObject`
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift`:
  - Update `SwitchSourceToolbarItem` if needed for new binding
- RxAppKit (local dependency):
  - Add `sectionItems` binding for `NSPopUpButton`
  - Add `selectedItemRepresentedObject()` binding

## 9. Thread Safety

`RuntimeEngineManager` currently uses `@MainActor` for individual methods. New mutable state (`proxyServers`, `mirroredEngines`) will be accessed from Bonjour callbacks and Task contexts. Options:

- Mark `RuntimeEngineManager` as `@MainActor` (preferred — it's already UI-adjacent and most mutations happen on main thread)
- Or protect new dictionaries with a lock/actor isolation

This should be decided during implementation based on existing threading patterns in the class.
