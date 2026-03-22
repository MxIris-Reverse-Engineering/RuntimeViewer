# Engine Icons Design

## Overview

Add device-specific and app-specific icons to engine menu items. Local/Mac Catalyst engines show the device icon based on model identifier. Attached process engines show the app icon. Remote mirrored engines use the remote host's metadata for device icons, and fetch app icons asynchronously via the proxy server.

## 1. DeviceMetadata

Location: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/DeviceMetadata.swift`

Extensible device information struct with core typed fields and a dictionary for future additions.

```swift
public struct DeviceMetadata: Codable, Hashable, Sendable {
    public let modelIdentifier: String     // "Mac14,13", "iPhone16,2"
    public let osVersion: String           // "macOS 15.3", "iOS 18.2"
    public var additionalInfo: [String: String] = [:]
}
```

**Model identifier**: obtained via `sysctl("hw.model")` (works on both macOS and iOS).

**OS version**: formatted from `ProcessInfo.processInfo.operatingSystemVersion`.

A static `DeviceMetadata.current` property provides the local device's metadata.

## 2. HostInfo Extension

Add `metadata` to `HostInfo`:

```swift
public struct HostInfo: Codable, Hashable, Sendable {
    public let hostID: String
    public let hostName: String
    public let metadata: DeviceMetadata  // NEW
}
```

All `HostInfo` creation sites updated to include metadata. Default value uses `DeviceMetadata.current`.

**Bonjour TXT record**: Metadata is NOT transmitted via TXT record (255-byte limit, not suitable for structured data). Remote host metadata is transmitted through `RemoteEngineDescriptor` which already contains `HostInfo` data (via `hostName` and `originChain`). The `RemoteEngineDescriptor` will carry the full `DeviceMetadata` from the source host.

## 3. RemoteEngineDescriptor Extension

Add metadata to descriptors so remote hosts can provide their device info:

```swift
public struct RemoteEngineDescriptor: Codable, Hashable, Sendable {
    // ... existing fields ...
    public let metadata: DeviceMetadata  // NEW — source host's device metadata
}
```

Built in `RuntimeEngineManager.buildEngineDescriptors()` using `engine.hostInfo.metadata` (for local engines) or the mirrored engine's metadata (for transitive sharing).

## 4. Icon Logic

### 4.1 Device Icons (Local, Mac Catalyst)

For engines where `source` is `.local` or `.remote(identifier: .macCatalyst, ...)`:

```swift
NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
```

Works for both local and remote engines — remote engines have `metadata.modelIdentifier` from the `RemoteEngineDescriptor`.

### 4.2 Attached Process Icons (Local)

For locally attached engines (`.remote` non-Catalyst, `.localSocket`):

The app icon is obtained from `NSRunningApplication` matching the process, or `NSWorkspace.shared.icon(forFile:)` using the app bundle path.

The icon is stored on the `RuntimeEngine` or a cache keyed by source identifier.

### 4.3 Attached Process Icons (Remote Mirrored)

For remotely mirrored attached engines:

1. **Initial state**: Show `NSImage(systemSymbolName: "app.fill")` as placeholder
2. **Async fetch**: After the directTCP client connects to the proxy server, send an icon request
3. **Proxy server handles**: Looks up the source engine's attached process, gets its app icon, serializes as PNG data, returns it
4. **Client receives**: Caches the icon, triggers menu refresh

### 4.4 Icon Request Protocol (Proxy Server Layer)

The icon request uses a dedicated command name registered directly on the proxy server's connection, NOT through `RuntimeEngine.CommandNames`:

```swift
// In RuntimeEngineProxyServer:
private static let iconRequestCommand = "com.RuntimeViewer.ProxyServer.requestIcon"

// Handler registration (in setupRequestHandlers):
connection.setMessageHandler(name: Self.iconRequestCommand) { [engine] () -> Data? in
    // Get app icon for the engine's attached process
    // Return PNG data or nil
}
```

Client side: after connecting to proxy, send icon request and update cache on response.

## 5. UI Integration

In `MainWindowController`, the `itemImage` closure in `sectionItems` binding:

```swift
itemImage: { engine in
    if engine.source == .local || engine.source.identifier == RuntimeSource.Identifier.macCatalyst.rawValue {
        // Device icon from model identifier
        return NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
    } else if engine.hostInfo.hostID == RuntimeNetworkBonjour.localInstanceID {
        // Local attached — app icon (from cache or NSRunningApplication)
        return cachedIcon(for: engine) ?? .symbol(systemName: .app)
    } else {
        // Remote mirrored — cached icon or placeholder
        return cachedIcon(for: engine) ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
    }
}
```

Remote attach icons are fetched asynchronously after connection. When the icon arrives, `runtimeEngineSections` is re-emitted to trigger menu refresh.

## 6. Files to Create/Modify

### New Files
- `RuntimeViewerCore/Sources/RuntimeViewerCommunication/DeviceMetadata.swift`

### Modified Files
- `RuntimeViewerCore/Sources/RuntimeViewerCommunication/HostInfo.swift` — add `metadata: DeviceMetadata`
- `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RemoteEngineDescriptor.swift` — add `metadata: DeviceMetadata`
- `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift` — update `init` default `HostInfo` to include metadata
- `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift` — add icon request handler
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift` — pass metadata in descriptors, icon cache, async fetch
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift` — update `itemImage` closure
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeSource+.swift` — may need updates for icon logic
