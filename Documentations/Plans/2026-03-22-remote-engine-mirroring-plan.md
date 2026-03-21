# Remote Engine Mirroring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror all RuntimeEngines from remote Bonjour hosts, with transitive sharing, cycle detection, and UI grouping by host.

**Architecture:** Management channel piggybacks on existing Bonjour connection; data channels use directTCP per shared engine. A generic proxy server actor forwards requests and relays push data. UI groups engines by host using NSMenuItem section headers.

**Tech Stack:** Swift 5 language mode, Network.framework (NWListener/NWConnection), Combine, RxSwift/RxAppKit, SnapKit, UNUserNotificationCenter.

**Spec:** `Documentations/Plans/2026-03-21-remote-engine-mirroring-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `RuntimeViewerCore/Sources/RuntimeViewerCommunication/HostInfo.swift` | `HostInfo` struct (hostID + hostName) |
| `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RemoteEngineDescriptor.swift` | `RemoteEngineDescriptor` struct for engine list protocol |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift` | Proxy server actor: wraps any engine, exposes via directTCP |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineSection.swift` | `RuntimeEngineSection` struct for UI grouping |
| `RxAppKit: Sources/RxAppKit/Components/NSPopUpButton+Rx.swift` | Extend with `sectionItems` and `selectedItemRepresentedObject()` |

### Modified Files

| File | Changes |
|------|---------|
| `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeSource.swift` | Promote `identifier` to public |
| `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeNetwork.swift` | Add `rv-host-name` to Bonjour TXT record, extract hostName from discovered endpoints |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift` | Add `hostInfo`, `originChain` properties; add `engineList`/`engineListChanged` commands; add new overload + public methods |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift` | Add proxy server management, mirror reception, sections, lifecycle |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeConnectionNotificationService.swift` | Move `identifier`/`displayName` to RuntimeSource public API |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift` | Switch to section-based binding, identifier-based selection |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift` | Update bindings for sections and representedObject |

---

## Task 1: HostInfo and RuntimeSource.identifier

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/HostInfo.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeSource.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeConnectionNotificationService.swift`

- [ ] **Step 1: Create HostInfo.swift**

```swift
// RuntimeViewerCore/Sources/RuntimeViewerCommunication/HostInfo.swift
import Foundation

public struct HostInfo: Codable, Hashable, Sendable {
    public let hostID: String
    public let hostName: String

    public init(hostID: String, hostName: String) {
        self.hostID = hostID
        self.hostName = hostName
    }
}
```

- [ ] **Step 2: Promote identifier to public on RuntimeSource**

Move the `identifier` computed property from the `fileprivate` extension in `RuntimeConnectionNotificationService.swift` to a `public` extension on `RuntimeSource` in `RuntimeSource.swift`. The property body stays the same. Remove the `fileprivate` version from `RuntimeConnectionNotificationService.swift` (keep `displayName` as fileprivate there since it's only used locally).

In `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeSource.swift`, add at the bottom:

```swift
extension RuntimeSource {
    public var identifier: String {
        switch self {
        case .local:
            return "local"
        case .remote(_, let id, _):
            return id.rawValue
        case .bonjour(let name, let id, let role):
            return role.isClient ? "bonjour.\(name)" : "bonjourServer.\(id.rawValue)"
        case .localSocket(_, let id, let role):
            return role.isClient ? id.rawValue : "localSocketServer.\(id.rawValue)"
        case .directTCP(let name, let host, let port, let role):
            return role.isClient ? "tcp.\(name).\(host ?? "").\(port)" : "tcpServer.\(name).\(port)"
        }
    }
}
```

Check if `RuntimeSource` has a `macCatalystClient` static property — if it uses `.remote`, it will be handled by the `.remote` case. Verify.

In `RuntimeConnectionNotificationService.swift`, change `fileprivate var identifier` to use `source.identifier` (the now-public property). Remove the duplicate `identifier` computed property from the fileprivate extension.

- [ ] **Step 3: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/HostInfo.swift \
  RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeSource.swift \
  RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeConnectionNotificationService.swift
git commit -m "feat: add HostInfo struct and promote RuntimeSource.identifier to public"
```

---

## Task 2: RemoteEngineDescriptor

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RemoteEngineDescriptor.swift`

- [ ] **Step 1: Create RemoteEngineDescriptor.swift**

```swift
// RuntimeViewerCore/Sources/RuntimeViewerCommunication/RemoteEngineDescriptor.swift
import Foundation

public struct RemoteEngineDescriptor: Codable, Hashable, Sendable {
    public let engineID: String
    public let source: RuntimeSource
    public let hostName: String
    public let originChain: [String]
    public let directTCPHost: String
    public let directTCPPort: UInt16

    public init(
        engineID: String,
        source: RuntimeSource,
        hostName: String,
        originChain: [String],
        directTCPHost: String,
        directTCPPort: UInt16
    ) {
        self.engineID = engineID
        self.source = source
        self.hostName = hostName
        self.originChain = originChain
        self.directTCPHost = directTCPHost
        self.directTCPPort = directTCPPort
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/RemoteEngineDescriptor.swift
git commit -m "feat: add RemoteEngineDescriptor for engine list protocol"
```

---

## Task 3: Bonjour TXT Record Enhancement

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeNetwork.swift`

- [ ] **Step 1: Add rv-host-name to TXT record**

In `RuntimeNetworkBonjour`, add a static `hostName` property and include it in the TXT record:

```swift
// Add to RuntimeNetworkBonjour enum:
public static let hostNameKey = "rv-host-name"
public static let localHostName: String = {
    #if canImport(UIKit)
    return UIDevice.current.name
    #else
    return (SCDynamicStoreCopyComputerName(nil, nil) as? String)
        ?? ProcessInfo.processInfo.hostName
    #endif
}()
```

In `makeService(name:)` (or wherever TXT record is built), add:

```swift
txtRecord[hostNameKey] = localHostName
```

- [ ] **Step 2: Extract hostName from discovered endpoints**

In `RuntimeNetworkBonjour`, add a `hostName(from:)` method mirroring the existing `instanceID(from:)`:

```swift
public static func hostName(from metadata: NWBrowser.Result.Metadata) -> String? {
    guard case .bonjour(let record) = metadata else { return nil }
    return record[hostNameKey]
}
```

In `RuntimeNetworkEndpoint`, add a `hostName` property (excluded from `Equatable`/`Hashable`, same pattern as `instanceID`):

```swift
public let hostName: String?
```

Update `RuntimeNetworkEndpoint.init` to accept `hostName`. In `RuntimeNetworkBrowser.start()`, extract `hostName` from the TXT record in the `onAdded` callback alongside `instanceID` and pass it to the `RuntimeNetworkEndpoint` initializer.

- [ ] **Step 3: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeNetwork.swift
git commit -m "feat: add rv-host-name to Bonjour TXT record"
```

---

## Task 4: RuntimeEngine Identity Properties

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`

- [ ] **Step 1: Add hostInfo and originChain to RuntimeEngine**

Add two new `nonisolated let` properties. Update the `init` to accept optional `hostInfo` and `originChain` with defaults:

```swift
// After existing `public nonisolated let source: RuntimeSource` (line 78):
public nonisolated let hostInfo: HostInfo
public nonisolated let originChain: [String]

// Update init (line 125):
public init(
    source: RuntimeSource,
    hostInfo: HostInfo = HostInfo(
        hostID: RuntimeNetworkBonjour.localInstanceID,
        hostName: RuntimeNetworkBonjour.localHostName
    ),
    originChain: [String] = [RuntimeNetworkBonjour.localInstanceID]
) {
    self.source = source
    self.hostInfo = hostInfo
    self.originChain = originChain
    self.objcSectionFactory = .init()
    self.swiftSectionFactory = .init()
}
```

The `static let local` (line 70) needs no change — it will use defaults.

- [ ] **Step 2: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20`

Expected: BUILD SUCCEEDED (existing callers use default params)

- [ ] **Step 3: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
git commit -m "feat: add hostInfo and originChain properties to RuntimeEngine"
```

---

## Task 5: Engine Management Commands in RuntimeEngine

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`

- [ ] **Step 1: Add CommandNames cases**

Add to the `CommandNames` enum (after `memberAddresses`):

```swift
case engineList
case engineListChanged
```

- [ ] **Step 2: Add new setMessageHandlerBinding overload**

Add after the existing four overloads (after line ~275):

```swift
/// Overload for commands with no request body but a response.
private func setMessageHandlerBinding<Response: Codable>(
    forName name: CommandNames,
    respond: @escaping (isolated RuntimeEngine) async throws -> Response
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
```

- [ ] **Step 3: Add engineList handler in setupMessageHandlerForServer**

Add at the end of `setupMessageHandlerForServer()` (line ~223):

```swift
setMessageHandlerBinding(forName: .engineList) { engine -> [RemoteEngineDescriptor] in
    await RuntimeEngineManager.shared.buildEngineDescriptors()
}
```

**Note:** This creates a dependency from `RuntimeViewerCore` to `RuntimeEngineManager` which lives in the app target. This won't compile as-is. Instead, use a delegate/callback pattern:

```swift
// Add to RuntimeEngine:
public static var engineListProvider: (() async -> [RemoteEngineDescriptor])?

// In setupMessageHandlerForServer():
setMessageHandlerBinding(forName: .engineList) { engine -> [RemoteEngineDescriptor] in
    await RuntimeEngine.engineListProvider?() ?? []
}
```

`RuntimeEngineManager` will set `RuntimeEngine.engineListProvider` during initialization.

- [ ] **Step 4: Add engineListChanged handler in setupMessageHandlerForClient**

Add at the end of `setupMessageHandlerForClient()` (line ~231):

```swift
setMessageHandlerBinding(forName: .engineListChanged) { (engine: RuntimeEngine, descriptors: [RemoteEngineDescriptor]) in
    await RuntimeEngine.engineListChangedHandler?(descriptors, engine)
}
```

And add the static callback:

```swift
public static var engineListChangedHandler: (([RemoteEngineDescriptor], RuntimeEngine) async -> Void)?
```

- [ ] **Step 5: Add requestEngineList() public method**

Add in the `// MARK: - Requests` section:

```swift
public func requestEngineList() async throws -> [RemoteEngineDescriptor] {
    try await request {
        []
    } remote: {
        try await $0.sendMessage(name: .engineList)
    }
}
```

- [ ] **Step 6: Add pushEngineListChanged() public method**

```swift
public func pushEngineListChanged(_ descriptors: [RemoteEngineDescriptor]) async throws {
    guard let connection, source.remoteRole?.isServer == true else { return }
    try await connection.sendMessage(name: .engineListChanged, request: descriptors)
}
```

- [ ] **Step 7: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
git commit -m "feat: add engine list management commands to RuntimeEngine"
```

---

## Task 6: RuntimeEngineProxyServer

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift`

- [ ] **Step 1: Update RuntimeEngine.swift access levels**

In `RuntimeEngine.swift`, widen access so the proxy server (same module) can reference these types:
- Change `fileprivate enum CommandNames` → `internal enum CommandNames` (line 49)
- Change `private struct InterfaceRequest` → `internal struct InterfaceRequest` (line 415)
- Change `private struct MemberAddressesRequest` → `internal struct MemberAddressesRequest` (line 455)
- Change `fileprivate func sendMessage` extensions on RuntimeConnection → `internal` (lines 481-496)

- [ ] **Step 2: Create RuntimeEngineProxyServer**

```swift
// RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift
import Foundation
import Combine
import RuntimeViewerCommunication

public actor RuntimeEngineProxyServer {
    public let engine: RuntimeEngine
    private let communicator = RuntimeCommunicator()
    private var connection: RuntimeConnection?
    private var subscriptions: Set<AnyCancellable> = []
    private let identifier: String

    public private(set) var port: UInt16 = 0
    public private(set) var host: String = ""

    public init(engine: RuntimeEngine, identifier: String) {
        self.engine = engine
        self.identifier = identifier
    }

    public func start() async throws {
        let source = RuntimeSource.directTCP(
            name: identifier,
            host: nil,
            port: 0,
            role: .server
        )
        connection = try await communicator.connect(to: source)
        // Extract the actual host/port from the underlying connection
        // This requires reading from the directTCP server connection after it starts
        if let conn = connection as? RuntimeDirectTCPServerConnection {
            port = conn.port
            host = conn.host
        }
        setupRequestHandlers()
        setupPushRelay()
    }

    public func stop() {
        connection?.stop()
        subscriptions.removeAll()
    }

    private func setupRequestHandlers() {
        guard let connection else { return }

        connection.setMessageHandler(name: CommandNames.isImageLoaded.commandName) {
            [engine] (path: String) -> Bool in
            try await engine.isImageLoaded(path: path)
        }

        connection.setMessageHandler(name: CommandNames.runtimeObjectsInImage.commandName) {
            [engine] (image: String) -> [RuntimeObject] in
            try await engine.objects(in: image)
        }

        connection.setMessageHandler(name: CommandNames.runtimeInterfaceForRuntimeObjectInImageWithOptions.commandName) {
            [engine] (request: InterfaceRequest) -> RuntimeObjectInterface? in
            try await engine.interface(for: request.object, options: request.options)
        }

        connection.setMessageHandler(name: CommandNames.runtimeObjectHierarchy.commandName) {
            [engine] (object: RuntimeObject) -> [String] in
            try await engine.hierarchy(for: object)
        }

        connection.setMessageHandler(name: CommandNames.loadImage.commandName) {
            [engine] (path: String) in
            try await engine.loadImage(at: path)
        }

        connection.setMessageHandler(name: CommandNames.imageNameOfClassName.commandName) {
            [engine] (name: RuntimeObject) -> String? in
            try await engine.imageName(ofObjectName: name)
        }

        connection.setMessageHandler(name: CommandNames.memberAddresses.commandName) {
            [engine] (request: MemberAddressesRequest) -> [RuntimeMemberAddress] in
            try await engine.memberAddresses(for: request.object, memberName: request.memberName)
        }
    }

    private func setupPushRelay() {
        guard let connection else { return }

        engine.$imageNodes
            .dropFirst()
            .sink { imageNodes in
                Task {
                    try? await connection.sendMessage(
                        name: CommandNames.imageNodes.commandName,
                        request: imageNodes
                    )
                }
            }
            .store(in: &subscriptions)

        engine.reloadDataPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task {
                    let imageList = await self.engine.imageList
                    try? await connection.sendMessage(
                        name: CommandNames.imageList.commandName,
                        request: imageList
                    )
                    try? await connection.sendMessage(
                        name: CommandNames.reloadData.commandName
                    )
                }
            }
            .store(in: &subscriptions)
    }
}

// Access fileprivate CommandNames from RuntimeEngine's file.
// Since CommandNames is fileprivate to RuntimeEngine.swift, we need to
// either make it internal or duplicate the command name strings.
// Preferred: Change CommandNames access to `internal` in RuntimeEngine.swift.
```

**Important implementation note**: `RuntimeEngine.CommandNames` is `fileprivate`. The proxy server needs access to command name strings. Options:
1. Change `CommandNames` from `fileprivate` to `internal` in RuntimeEngine.swift
2. Add a public `static let` for each command name string on RuntimeEngine

Preferred: Option 1 — change to `internal enum CommandNames`.

Also, `InterfaceRequest` and `MemberAddressesRequest` are `private` nested types in RuntimeEngine. They are already made `internal` in Step 1.

- [ ] **Step 3: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift \
  RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
git commit -m "feat: add RuntimeEngineProxyServer for proxying engine data via directTCP"
```

---

## Task 7: RxAppKit Extensions

**Files:**
- Modify: `/Volumes/Repositories/Private/Personal/Library/macOS/RxAppKit/Sources/RxAppKit/Components/NSPopUpButton+Rx.swift`

**Prerequisite:** Enable local RxAppKit dependency in `RuntimeViewerPackages/Package.swift` by setting `isEnabled: true` for the local path entries.

- [ ] **Step 1: Enable local RxAppKit dependency**

In `RuntimeViewerPackages/Package.swift`, find the RxAppKit local package dependency entry and set `isEnabled: true`.

- [ ] **Step 2: Add sectionItems binding**

In `NSPopUpButton+Rx.swift`, add:

```swift
extension Reactive where Base: NSPopUpButton {
    /// Binds section-grouped items to a popup button using NSMenuItem.sectionHeader.
    public func sectionItems<Section, Item>(
        sectionTitle: @escaping (Section) -> String,
        items: @escaping (Section) -> [Item],
        itemTitle: @escaping (Item) -> String,
        itemRepresentedObject: @escaping (Item) -> AnyHashable
    ) -> Binder<[Section]> {
        Binder(base) { popUpButton, sections in
            let previousRepresentedObject = popUpButton.selectedItem?.representedObject as? AnyHashable

            popUpButton.menu?.removeAllItems()

            for section in sections {
                let header = NSMenuItem.sectionHeader(title: sectionTitle(section))
                popUpButton.menu?.addItem(header)

                for item in items(section) {
                    let menuItem = NSMenuItem(title: itemTitle(item), action: nil, keyEquivalent: "")
                    menuItem.representedObject = itemRepresentedObject(item)
                    popUpButton.menu?.addItem(menuItem)
                }
            }

            // Restore selection by representedObject
            if let previousRepresentedObject {
                let index = popUpButton.menu?.items.firstIndex {
                    ($0.representedObject as? AnyHashable) == previousRepresentedObject
                }
                if let index {
                    popUpButton.selectItem(at: index)
                }
            } else {
                // Select first selectable item
                let index = popUpButton.menu?.items.firstIndex { $0.isEnabled && !$0.isSeparatorItem }
                if let index {
                    popUpButton.selectItem(at: index)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Add selectedItemRepresentedObject binding**

```swift
extension Reactive where Base: NSPopUpButton {
    /// Emits the representedObject of the selected item when selection changes.
    public func selectedItemRepresentedObject<T: Hashable>(_ type: T.Type = T.self) -> ControlEvent<T?> {
        let source = controlEvent
            .map { [weak base] _ -> T? in
                base?.selectedItem?.representedObject as? T
            }
        return ControlEvent(events: source)
    }
}
```

- [ ] **Step 4: Build RxAppKit to verify**

Run: `cd /Volumes/Repositories/Private/Personal/Library/macOS/RxAppKit && swift build 2>&1 | head -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit RxAppKit changes**

```bash
cd /Volumes/Repositories/Private/Personal/Library/macOS/RxAppKit
git add Sources/RxAppKit/Components/NSPopUpButton+Rx.swift
git commit -m "feat: add sectionItems and selectedItemRepresentedObject bindings for NSPopUpButton"
```

- [ ] **Step 6: Commit RuntimeViewer Package.swift change**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git add RuntimeViewerPackages/Package.swift
git commit -m "chore: enable local RxAppKit dependency for sectionItems extension"
```

---

## Task 8: RuntimeEngineSection and RuntimeEngineManager Server-Side

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineSection.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift`

**Thread safety**: `RuntimeEngineManager` already uses `@MainActor` on key methods (e.g. `connectToBonjourEndpoint`). Mark the entire class as `@MainActor` to protect all new mutable state (`proxyServers`, `mirroredEngines`, `runtimeEngineSections`). Add `@MainActor` to the class declaration.

- [ ] **Step 0: Mark RuntimeEngineManager as @MainActor**

Change the class declaration from:
```swift
public final class RuntimeEngineManager: Loggable {
```
to:
```swift
@MainActor
public final class RuntimeEngineManager: Loggable {
```

Remove individual `@MainActor` annotations from methods that already have them (they become redundant). Fix any resulting compilation issues with `nonisolated` where needed (e.g. for `Loggable` protocol conformance).

- [ ] **Step 1: Create RuntimeEngineSection**

```swift
// RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineSection.swift
import RuntimeViewerCore
import RuntimeViewerCommunication

public struct RuntimeEngineSection {
    public let hostName: String
    public let hostID: String
    public let engines: [RuntimeEngine]
}
```

- [ ] **Step 2: Add server-side properties to RuntimeEngineManager**

Add new properties:

```swift
private var proxyServers: [String: RuntimeEngineProxyServer] = [:]
@Published public private(set) var mirroredEngines: [String: RuntimeEngine] = [:]
```

- [ ] **Step 3: Add buildEngineDescriptors()**

```swift
func buildEngineDescriptors() async -> [RemoteEngineDescriptor] {
    var descriptors: [RemoteEngineDescriptor] = []
    for engine in runtimeEngines {
        // Skip the bonjour server engine itself
        guard engine !== bonjourServerEngine else { continue }
        guard let proxy = proxyServers[engine.source.identifier] else { continue }
        let descriptor = RemoteEngineDescriptor(
            engineID: engine.source.identifier,
            source: engine.source,
            hostName: engine.hostInfo.hostName,
            originChain: engine.originChain + [RuntimeNetworkBonjour.localInstanceID],
            directTCPHost: await proxy.host,
            directTCPPort: await proxy.port
        )
        descriptors.append(descriptor)
    }
    return descriptors
}
```

- [ ] **Step 4: Add startSharingEngines()**

```swift
func startSharingEngines() {
    // Set up the static callbacks on RuntimeEngine
    RuntimeEngine.engineListProvider = { [weak self] in
        guard let self else { return [] }
        return await self.buildEngineDescriptors()
    }

    // Observe engine list changes and manage proxy servers
    rx.runtimeEngines
        .driveOnNext { [weak self] engines in
            guard let self else { return }
            Task {
                await self.updateProxyServers(for: engines)
            }
        }
        .disposed(by: rx.disposeBag)
}

private func updateProxyServers(for engines: [RuntimeEngine]) async {
    let currentIDs = Set(engines.map { $0.source.identifier })
    let existingIDs = Set(proxyServers.keys)

    // Remove proxy servers for engines that no longer exist
    for id in existingIDs.subtracting(currentIDs) {
        await proxyServers[id]?.stop()
        proxyServers.removeValue(forKey: id)
    }

    // Add proxy servers for new engines (skip bonjour server engine)
    for engine in engines {
        let id = engine.source.identifier
        guard !existingIDs.contains(id) else { continue }
        guard engine !== bonjourServerEngine else { continue }

        do {
            let proxy = RuntimeEngineProxyServer(engine: engine, identifier: id)
            try await proxy.start()
            proxyServers[id] = proxy
        } catch {
            Self.logger.error("Failed to start proxy server for \(id, privacy: .public): \(error, privacy: .public)")
        }
    }

    // Push updated engine list to management client
    if let bonjourServerEngine {
        let descriptors = await buildEngineDescriptors()
        try? await bonjourServerEngine.pushEngineListChanged(descriptors)
    }
}
```

- [ ] **Step 5: Add runtimeEngineSections computed property**

```swift
@Published public private(set) var runtimeEngineSections: [RuntimeEngineSection] = []

private func rebuildSections() {
    var sections: [RuntimeEngineSection] = []
    var hostIDToIndex: [String: Int] = [:]

    for engine in runtimeEngines {
        let hostID = engine.hostInfo.hostID
        if let index = hostIDToIndex[hostID] {
            let section = sections[index]
            sections[index] = RuntimeEngineSection(
                hostName: section.hostName,
                hostID: section.hostID,
                engines: section.engines + [engine]
            )
        } else {
            hostIDToIndex[hostID] = sections.count
            sections.append(RuntimeEngineSection(
                hostName: engine.hostInfo.hostName,
                hostID: hostID,
                engines: [engine]
            ))
        }
    }

    runtimeEngineSections = sections
}
```

Call `rebuildSections()` whenever engine arrays change.

- [ ] **Step 6: Wire startSharingEngines in init**

Call `startSharingEngines()` at the end of `init()`.

- [ ] **Step 7: Add Rx extension for sections**

```swift
extension Reactive where Base == RuntimeEngineManager {
    public var runtimeEngineSections: Driver<[RuntimeEngineSection]> {
        base.$runtimeEngineSections.asObservable().asDriver(onErrorJustReturn: [])
    }
}
```

- [ ] **Step 8: Build to verify**

Build the full Xcode project to verify:

Run: `xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift`

Expected: BUILD SUCCEEDED

- [ ] **Step 9: Add RuntimeEngineSection.swift to Xcode project**

Use Xcode MCP `XcodeWrite` or manually add the file reference to `project.pbxproj` under the `RuntimeViewerUsingAppKit` target. (`RuntimeEngineProxyServer.swift` is in the SPM package and doesn't need manual project file inclusion.)

- [ ] **Step 10: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineSection.swift \
  RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift \
  RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj
git commit -m "feat: add proxy server management and engine sections to RuntimeEngineManager"
```

---

## Task 9: RuntimeEngineManager Client-Side (Mirror Reception)

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift`

- [ ] **Step 1: Set up engineListChangedHandler**

In `init()` or `startSharingEngines()`, add:

```swift
RuntimeEngine.engineListChangedHandler = { [weak self] descriptors, engine in
    guard let self else { return }
    await MainActor.run {
        self.handleEngineListChanged(descriptors, from: engine)
    }
}
```

- [ ] **Step 2: Add handleEngineListChanged()**

```swift
@MainActor
func handleEngineListChanged(_ descriptors: [RemoteEngineDescriptor], from engine: RuntimeEngine) {
    let currentIDs = Set(mirroredEngines.keys)
    let newIDs = Set(descriptors.map(\.engineID))

    // Remove engines no longer in the list
    for id in currentIDs.subtracting(newIDs) {
        if let engine = mirroredEngines.removeValue(forKey: id) {
            Task { await engine.stop() }
        }
    }

    // Add new engines
    for descriptor in descriptors {
        guard !currentIDs.contains(descriptor.engineID) else { continue }

        // Cycle check
        if descriptor.originChain.contains(RuntimeNetworkBonjour.localInstanceID) {
            Self.logger.info("Skipping mirrored engine \(descriptor.engineID, privacy: .public): cycle detected")
            continue
        }

        // Dedup check
        if runtimeEngines.contains(where: { $0.source.identifier == descriptor.engineID }) {
            Self.logger.info("Skipping mirrored engine \(descriptor.engineID, privacy: .public): already exists")
            continue
        }

        let mirroredEngine = RuntimeEngine(
            source: .directTCP(
                name: descriptor.hostName + "/" + descriptor.source.description,
                host: descriptor.directTCPHost,
                port: descriptor.directTCPPort,
                role: .client
            ),
            hostInfo: HostInfo(
                hostID: descriptor.originChain.first ?? "",
                hostName: descriptor.hostName
            ),
            originChain: descriptor.originChain
        )

        mirroredEngines[descriptor.engineID] = mirroredEngine

        Task {
            do {
                try await mirroredEngine.connect()
            } catch {
                Self.logger.error("Failed to connect mirrored engine \(descriptor.engineID, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    rebuildSections()
}
```

- [ ] **Step 3: Request engine list after Bonjour client connects**

In `connectToBonjourEndpoint()`, after the engine connects successfully, request the engine list:

```swift
// After engine.connect(bonjourEndpoint:) succeeds:
Task {
    do {
        let descriptors = try await engine.requestEngineList()
        await MainActor.run {
            self.handleEngineListChanged(descriptors, from: engine)
        }
    } catch {
        Self.logger.error("Failed to request engine list: \(error, privacy: .public)")
    }
}
```

- [ ] **Step 4: Clean up mirrored engines on Bonjour disconnect**

In `observeRuntimeEngineState()`, when a Bonjour client engine disconnects, also remove its mirrored engines:

```swift
// In the .disconnected handler, after existing cleanup:
if runtimeEngine.source.remoteRole?.isClient == true {
    // Find and remove all mirrored engines from this host
    let hostID = runtimeEngine.hostInfo.hostID
    for (id, engine) in mirroredEngines where engine.hostInfo.hostID == hostID {
        Task { await engine.stop() }
        mirroredEngines.removeValue(forKey: id)
    }
    rebuildSections()
}
```

- [ ] **Step 5: Update runtimeEngines computed property**

```swift
public var runtimeEngines: [RuntimeEngine] {
    systemRuntimeEngines + attachedRuntimeEngines + bonjourRuntimeEngines + Array(mirroredEngines.values)
}
```

Also update the Rx extension to include mirrored engines:

```swift
public var runtimeEngines: Driver<[RuntimeEngine]> {
    Driver.combineLatest(
        base.$systemRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []),
        base.$attachedRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []),
        base.$bonjourRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []),
        base.$mirroredEngines.asObservable().asDriver(onErrorJustReturn: [:]),
        resultSelector: { $0 + $1 + $2 + Array($3.values) }
    )
}
```

- [ ] **Step 6: Build to verify**

Run: `xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift`

Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift
git commit -m "feat: add mirror reception and lifecycle management to RuntimeEngineManager"
```

---

## Task 10: UI — Section-Based Source Menu

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift`

- [ ] **Step 1: Update MainViewModel.Input**

Change `switchSource` type:

```swift
// Before:
let switchSource: Signal<Int>
// After:
let switchSource: Signal<String?>  // engine identifier from representedObject
```

- [ ] **Step 2: Update MainViewModel.Output**

Replace flat list with sections:

```swift
// Before:
let runtimeSources: Driver<[RuntimeSource]>
let selectedRuntimeSourceIndex: Driver<Int>
// After:
let runtimeEngineSections: Driver<[RuntimeEngineSection]>
let selectedEngineIdentifier: Driver<String>
```

- [ ] **Step 3: Update MainViewModel.transform()**

Replace the `switchSource` handling:

```swift
// Before:
input.switchSource.emit(with: self) {
    $0.router.trigger(.main($0.runtimeEngineManager.runtimeEngines[$1]))
    $0.selectedRuntimeSourceIndex.accept($1)
}.disposed(by: rx.disposeBag)

// After:
input.switchSource.compactMap { $0 }.emit(with: self) { owner, identifier in
    guard let engine = owner.runtimeEngineManager.runtimeEngines.first(where: {
        $0.source.identifier == identifier
    }) else { return }
    owner.router.trigger(.main(engine))
    owner.selectedEngineIdentifier.accept(identifier)
}.disposed(by: rx.disposeBag)
```

Update the `selectedRuntimeSourceIndex` relay to `selectedEngineIdentifier: BehaviorRelay<String>`:

```swift
// Initialize with local engine identifier:
private let selectedEngineIdentifier = BehaviorRelay<String>(value: RuntimeSource.local.identifier)
```

Update output:

```swift
runtimeEngineSections: runtimeEngineManager.rx.runtimeEngineSections,
selectedEngineIdentifier: selectedEngineIdentifier.asDriver(),
```

- [ ] **Step 4: Update MainWindowController setupBindings**

```swift
// Before:
switchSource: toolbarController.switchSourceItem.popUpButton.rx.selectedItemIndex().asSignal(),

// After:
switchSource: toolbarController.switchSourceItem.popUpButton.rx
    .selectedItemRepresentedObject(String.self)
    .asSignal(),
```

Replace the output bindings:

```swift
// Before:
output.selectedRuntimeSourceIndex.drive(toolbarController.switchSourceItem.popUpButton.rx.selectedIndex())
    .disposed(by: rx.disposeBag)
output.runtimeSources.drive(toolbarController.switchSourceItem.popUpButton.rx.items())
    .disposed(by: rx.disposeBag)

// After:
output.runtimeEngineSections.drive(
    toolbarController.switchSourceItem.popUpButton.rx.sectionItems(
        sectionTitle: { $0.hostName },
        items: { $0.engines },
        itemTitle: { $0.source.description },
        itemRepresentedObject: { AnyHashable($0.source.identifier) }
    )
).disposed(by: rx.disposeBag)
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift`

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift \
  RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift
git commit -m "feat: switch toolbar source menu to section-based grouping by host"
```

---

## Task 11: Integration Testing and Final Polish

- [ ] **Step 1: Verify Bonjour self-discovery still works**

Launch the app, confirm it does not connect to itself (check logs for "Skipping self Bonjour endpoint").

- [ ] **Step 2: Verify toolbar menu shows sections**

With only local engines, the menu should show a single section header ("本机" or computer name) with "My Mac" underneath.

- [ ] **Step 3: Test with a second Mac (if available)**

Connect two Macs on the same network. Verify:
- Remote host appears as a new section in the toolbar menu
- Remote engines are browsable
- Disconnecting the remote host removes its section and shows a notification

- [ ] **Step 4: Final build verification**

Run: `xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit any remaining changes**

```bash
git add -A
git commit -m "chore: integration polish and project file updates"
```

---

## Summary

| Task | Description | Key Files |
|------|-------------|-----------|
| 1 | HostInfo + RuntimeSource.identifier | HostInfo.swift, RuntimeSource.swift |
| 2 | RemoteEngineDescriptor | RemoteEngineDescriptor.swift |
| 3 | Bonjour TXT record enhancement | RuntimeNetwork.swift |
| 4 | RuntimeEngine identity properties | RuntimeEngine.swift |
| 5 | Engine management commands | RuntimeEngine.swift |
| 6 | RuntimeEngineProxyServer | RuntimeEngineProxyServer.swift, RuntimeEngine.swift |
| 7 | RxAppKit extensions | NSPopUpButton+Rx.swift |
| 8 | RuntimeEngineManager server-side | RuntimeEngineSection.swift, RuntimeEngineManager.swift |
| 9 | RuntimeEngineManager client-side | RuntimeEngineManager.swift |
| 10 | UI section-based source menu | MainViewModel.swift, MainWindowController.swift |
| 11 | Integration testing and polish | All files |
