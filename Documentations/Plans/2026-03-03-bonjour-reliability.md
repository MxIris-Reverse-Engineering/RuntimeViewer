# Bonjour Connection Reliability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix Bonjour discovery/connection reliability issues — intermittent device failures, no retry on connection loss, and iOS-first-start not being discovered by macOS.

**Architecture:** Patch the existing NWConnection/NWListener/NWBrowser handling with tolerance windows, error recovery, deduplication, and retry logic. No structural changes to RuntimeEngine or RuntimeCommunicator.

**Tech Stack:** Network.framework (NWConnection, NWListener, NWBrowser), Combine, Foundation

---

### Task 1: Write evolution document

**Files:**
- Create: `Documentations/Evolution/2026-03-03-bonjour-reliability.md`

**Step 1: Create evolution document**

Write the document describing all identified issues, root causes, and the fixes applied. Content:

```markdown
# Bonjour Connection Reliability Improvements

Date: 2026-03-03

## Problem Statement

Bonjour-based discovery and connection between macOS and iOS devices suffered from
several reliability issues:

1. **Intermittent device-specific failures** — Some devices could never connect even
   after granting local network permissions
2. **iOS-first-start not discovered** — If iOS app started before macOS, macOS would
   consistently fail to connect to the already-advertising iOS device
3. **No recovery from transient failures** — Any connection hiccup was permanent

## Root Cause Analysis

### Issue 1: NWConnection `.waiting` state immediately killed

`RuntimeNetworkConnection.handleStateChange` treated `.waiting` as a fatal error,
calling `stop()` immediately. `.waiting` is a **transient** state indicating the
connection is waiting for a viable network path (e.g., during permission negotiation,
DNS resolution, or brief network transitions). On some devices/networks, connections
pass through `.waiting` briefly before reaching `.ready`.

**File:** `RuntimeNetworkConnection.swift:152-154`

### Issue 2: NWListener errors silently ignored

`RuntimeNetworkServerConnection.waitForConnection` set a `stateUpdateHandler` on the
NWListener that only logged state changes. If the listener entered `.failed`, the
continuation was never resumed — the iOS app would hang forever with no error feedback
and no retry.

**File:** `RuntimeNetworkConnection.swift:355-357`

### Issue 3: `restartListening` reused cancelled NWListener

After the first client connected, `listener.cancel()` was called (line 404). The
`restartListening()` method then tried to set `newConnectionHandler` on the cancelled
listener without calling `start()` again. A cancelled NWListener cannot be reused —
a new instance must be created.

**File:** `RuntimeNetworkConnection.swift:403-404, 411-443`

### Issue 4: `browseResultsChangedHandler` iterated all results

Every time NWBrowser reported a change (any service added/removed), the handler
iterated **all** results and called the discovery handler for each. This caused
duplicate RuntimeEngine creation for already-connected devices.

**File:** `RuntimeNetwork.swift:95-102`

### Issue 5: No deduplication in RuntimeEngineManager

`appendBonjourRuntimeEngine` blindly appended without checking if an engine for
the same endpoint already existed.

**File:** `RuntimeEngineManager.swift:60-63`

### Issue 6: No retry on connection failure

When a Bonjour connection attempt failed, the endpoint was permanently discarded.
No retry mechanism existed.

**File:** `RuntimeEngineManager.swift:44-46`

## Fixes Applied

### Fix 1: `.waiting` tolerance window (10s timeout)

Instead of immediately stopping on `.waiting`, start a 10-second timer. If the
connection reaches `.ready` within the window, cancel the timer. If the timer fires,
then stop the connection.

### Fix 2: NWListener `.failed` handling + 30s total timeout

The listener's `stateUpdateHandler` now handles `.failed` by resuming the continuation
with an error. A 30-second timeout is added to `waitForConnection` to prevent
indefinite hangs.

### Fix 3: Recreate NWListener in `restartListening`

Instead of reusing the cancelled listener, `restartListening` now creates a fresh
NWListener with the same parameters and service name.

### Fix 4: Process only `.added` changes in browser

`browseResultsChangedHandler` now iterates `changes` (filtering for `.added`) instead
of iterating all `results`. A separate `removedHandler` callback is added for
endpoint removal.

### Fix 5: Endpoint deduplication in RuntimeEngineManager

A `Set<String>` tracks known endpoint names. Duplicate discovery callbacks are ignored.
Endpoints are removed from the set when their engine disconnects.

### Fix 6: Exponential backoff retry (3 attempts)

Failed Bonjour connections are retried up to 3 times with 2s/4s/8s delays.
```

**Step 2: Commit**

```bash
git add Documentations/Evolution/2026-03-03-bonjour-reliability.md
git commit -m "docs: add Bonjour reliability evolution document"
```

---

### Task 2: NWConnection `.waiting` tolerance window

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeNetworkConnection.swift`

**Step 1: Add waiting timeout property and timer**

Add a `waitingTimeoutWork` property to `RuntimeNetworkConnection`:

```swift
private var waitingTimeoutWork: DispatchWorkItem?
```

**Step 2: Replace `.waiting` handling in `handleStateChange`**

Replace the `.waiting` case (line 152-154) with tolerance window logic:

```swift
case .waiting(let error):
    #log(.default, "Connection is waiting: \(error, privacy: .public)")
    // Start tolerance window — allow transient .waiting during permission
    // negotiation, DNS resolution, or brief network transitions
    if waitingTimeoutWork == nil {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            #log(.error, "Connection waiting timeout exceeded, stopping")
            self.stop(with: .networkError("Connection waiting timeout: \(error.localizedDescription)"))
        }
        waitingTimeoutWork = work
        queue.asyncAfter(deadline: .now() + 10, execute: work)
    }
```

**Step 3: Cancel timer on `.ready`**

In the `.ready` case (line 157-159), cancel the waiting timer:

```swift
case .ready:
    #log(.info, "Connection is ready")
    waitingTimeoutWork?.cancel()
    waitingTimeoutWork = nil
    stateSubject.send(.connected)
```

**Step 4: Cancel timer on `stop()`**

In both `stop()` methods, cancel the timer:

```swift
waitingTimeoutWork?.cancel()
waitingTimeoutWork = nil
```

**Step 5: Build**

Run: `xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeNetworkConnection.swift
git commit -m "fix: add .waiting tolerance window for NWConnection (10s timeout)"
```

---

### Task 3: NWListener error handling + timeout + restartListening fix

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeNetworkConnection.swift`

**Step 1: Store name and parameters for listener recreation**

Add stored properties to `RuntimeNetworkServerConnection`:

```swift
private let serviceName: String
private let listenerParameters: NWParameters
```

Initialize them in `init(name:)` before creating the listener:

```swift
self.serviceName = name

let tcpOptions = NWProtocolTCP.Options()
tcpOptions.enableKeepalive = true
tcpOptions.keepaliveIdle = 2
tcpOptions.noDelay = true

let parameters = NWParameters(tls: nil, tcp: tcpOptions)
parameters.includePeerToPeer = true
self.listenerParameters = parameters
```

**Step 2: Add listener `.failed` handling in `waitForConnection`**

Replace the listener stateUpdateHandler (line 355-357):

```swift
listener.stateUpdateHandler = { state in
    #log(.info, "Bonjour listener state: \(String(describing: state), privacy: .public)")
    switch state {
    case .failed(let error):
        if didResume.withLock({ !$0 }) {
            didResume.withLock { $0 = true }
            #log(.error, "Bonjour listener failed: \(error, privacy: .public)")
            continuation.resume(throwing: RuntimeConnectionError.networkError("Listener failed: \(error.localizedDescription)"))
        }
    default:
        break
    }
}
```

**Step 3: Add 30-second timeout to `waitForConnection`**

After `listener.start(queue: .main)` (line 407), add timeout:

```swift
listener.start(queue: .main)

DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    if didResume.withLock({ !$0 }) {
        didResume.withLock { $0 = true }
        #log(.error, "Bonjour listener timeout: no client connected within 30 seconds")
        listener.cancel()
        continuation.resume(throwing: RuntimeConnectionError.timeout)
    }
}
```

**Step 4: Fix `restartListening` to create new NWListener**

Replace the entire `restartListening()` method:

```swift
private func restartListening() async throws {
    #log(.info, "Restarting Bonjour listener with new instance...")

    let newListener = try NWListener(using: listenerParameters)
    newListener.service = NWListener.Service(name: serviceName, type: RuntimeNetworkBonjour.type)
    self.listener = newListener

    newListener.stateUpdateHandler = { state in
        #log(.info, "Restarted Bonjour listener state: \(String(describing: state), privacy: .public)")
    }

    newListener.newConnectionHandler = { [weak self] newConnection in
        guard let self else { return }

        #log(.info, "Accepted new Bonjour connection after restart: \(newConnection.debugDescription, privacy: .public)")

        do {
            let connection = try RuntimeNetworkConnection(connection: newConnection)
            self.underlyingConnection = connection

            self.connectionStateCancellable = connection.statePublisher
                .sink { [weak self] state in
                    #log(.info, "Bonjour reconnected connection state: \(String(describing: state), privacy: .public)")
                    if state.isDisconnected {
                        #log(.info, "Bonjour reconnected connection disconnected, restarting listener...")
                        Task { [weak self] in
                            try await self?.restartListening()
                        }
                    }
                }
        } catch {
            #log(.error, "Failed to create Bonjour connection on restart: \(error, privacy: .public)")
        }

        newListener.newConnectionHandler = nil
        newListener.cancel()
    }

    newListener.start(queue: .main)
}
```

**Step 5: Remove `listener.cancel()` from `waitForConnection` newConnectionHandler**

In the `newConnectionHandler` closure inside `waitForConnection` (lines 403-404), replace:
```swift
listener.newConnectionHandler = nil
listener.cancel()
```
with:
```swift
listener.newConnectionHandler = nil
// Don't cancel — restartListening will create a new listener when needed
```

Wait — actually we still need to stop the current listener to avoid accepting
multiple connections. Keep the cancel, but restartListening already handles creating
a new one. So keep lines 403-404 as-is.

**Step 6: Build**

Run: `xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeNetworkConnection.swift
git commit -m "fix: NWListener error handling, timeout, and restartListening recreation"
```

---

### Task 4: Fix browseResultsChangedHandler — only process `.added` changes

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeNetwork.swift`

**Step 1: Change `start` method signature to accept both added and removed callbacks**

```swift
public func start(
    onAdded: @escaping (RuntimeNetworkEndpoint) -> Void,
    onRemoved: @escaping (RuntimeNetworkEndpoint) -> Void
) {
```

**Step 2: Replace `browseResultsChangedHandler` to only process changes**

```swift
browser.browseResultsChangedHandler = { results, changes in
    #log(.info, "Browse results changed: \(results.count, privacy: .public) result(s), \(changes.count, privacy: .public) change(s)")
    for change in changes {
        switch change {
        case .added(let result):
            if case .service(let name, _, _, _) = result.endpoint {
                #log(.info, "Discovered new endpoint: \(name, privacy: .public)")
                onAdded(.init(name: name, endpoint: result.endpoint))
            }
        case .removed(let result):
            if case .service(let name, _, _, _) = result.endpoint {
                #log(.info, "Endpoint removed: \(name, privacy: .public)")
                onRemoved(.init(name: name, endpoint: result.endpoint))
            }
        default:
            break
        }
    }
}
```

**Step 3: Build**

Run: `xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -5`
Expected: FAIL — RuntimeEngineManager still uses old `start(handler:)` signature.

**Step 4: Commit (WIP)**

Don't commit yet — Task 5 will fix the call site.

---

### Task 5: Fix RuntimeEngineManager — deduplication + retry + removed handling

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift`

**Step 1: Add tracking set and retry constants**

```swift
private var knownBonjourEndpointNames: Set<String> = []
private static let maxRetryAttempts = 3
private static let retryBaseDelay: UInt64 = 2_000_000_000 // 2 seconds in nanoseconds
```

**Step 2: Replace browser.start call with new API**

Replace the `browser.start { ... }` block in `init()` with:

```swift
browser.start(
    onAdded: { [weak self] endpoint in
        guard let self else { return }
        Self.logger.info("Bonjour endpoint discovered: \(endpoint.name, privacy: .public), attempting connection...")
        Task { @MainActor in
            await self.connectToBonjourEndpoint(endpoint)
        }
    },
    onRemoved: { [weak self] endpoint in
        guard let self else { return }
        Self.logger.info("Bonjour endpoint removed: \(endpoint.name, privacy: .public)")
        Task { @MainActor in
            self.knownBonjourEndpointNames.remove(endpoint.name)
        }
    }
)
```

**Step 3: Add `connectToBonjourEndpoint` with deduplication and retry**

```swift
@MainActor
private func connectToBonjourEndpoint(_ endpoint: RuntimeNetworkEndpoint, attempt: Int = 0) async {
    guard !knownBonjourEndpointNames.contains(endpoint.name) else {
        Self.logger.info("Skipping duplicate Bonjour endpoint: \(endpoint.name, privacy: .public)")
        return
    }
    knownBonjourEndpointNames.insert(endpoint.name)

    do {
        let runtimeEngine = RuntimeEngine(source: .bonjourClient(endpoint: endpoint))
        try await runtimeEngine.connect()
        appendBonjourRuntimeEngine(runtimeEngine)
        Self.logger.info("Successfully connected to Bonjour endpoint: \(endpoint.name, privacy: .public)")
    } catch {
        Self.logger.error("Failed to connect to Bonjour endpoint: \(endpoint.name, privacy: .public) (attempt \(attempt + 1, privacy: .public)): \(error, privacy: .public)")
        knownBonjourEndpointNames.remove(endpoint.name)

        if attempt < Self.maxRetryAttempts {
            let delay = Self.retryBaseDelay * UInt64(1 << attempt) // 2s, 4s, 8s
            Self.logger.info("Retrying Bonjour connection to \(endpoint.name, privacy: .public) in \(delay / 1_000_000_000, privacy: .public)s...")
            try? await Task.sleep(nanoseconds: delay)
            await connectToBonjourEndpoint(endpoint, attempt: attempt + 1)
        } else {
            Self.logger.error("Exhausted retry attempts for Bonjour endpoint: \(endpoint.name, privacy: .public)")
        }
    }
}
```

**Step 4: Clean up `knownBonjourEndpointNames` on disconnect**

In `terminateRuntimeEngine(for:)`, add cleanup:

```swift
public func terminateRuntimeEngine(for source: RuntimeSource) {
    Self.logger.info("Terminating runtime engine: \(source.description, privacy: .public)")
    if case .bonjourClient(let endpoint) = source {
        knownBonjourEndpointNames.remove(endpoint.name)
    }
    systemRuntimeEngines.removeAll { $0.source == source }
    attachedRuntimeEngines.removeAll { $0.source == source }
    bonjourRuntimeEngines.removeAll { $0.source == source }
}
```

**Step 5: Build**

Run: `xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeNetwork.swift
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift
git commit -m "fix: Bonjour browser deduplication, retry, and removed endpoint handling"
```

---

### Task 6: Final build verification

**Step 1: Clean build**

Run: `xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 2: Verify iOS target also builds**

Run: `xcodebuild build -scheme RuntimeViewerUsingUIKit -configuration Debug -destination 'generic/platform=iOS Simulator' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 3: Final commit with all changes if any remaining**

```bash
git status
# If any unstaged changes remain, add and commit
```
