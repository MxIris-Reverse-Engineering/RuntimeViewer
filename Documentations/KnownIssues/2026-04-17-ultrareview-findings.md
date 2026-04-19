# 2026-04-17 Ultrareview Findings

**Review date:** 2026-04-17
**Branch reviewed:** `feature/socket-injected-endpoint-reconnection` @ `c88cb2b`
**Method:** `/ultrareview` (remote BugHunter pipeline, `rt7c91s0z`)
**Scope:** 125 files changed since `main`, 12,625 insertions / 1,553 deletions

## Status at a glance

| Class | Count | Notes |
|---|---:|---|
| Normal (tracked here) | 3 | Behavioural regressions and a concurrency contract leak |
| Nit (tracked here) | 3 | Quality polish; 1 is an RC.4 false-positive reactivated by new code |

## How to use this document

- Each row has a stable ID `UR.<N>`. Reference from commit messages (`fix(UR.3): …`).
- "Reproduction" column tracks whether a failing test case has been produced:
  - **Pending** — not yet attempted
  - **Confirmed** — a new/modified test fails against the current code
  - **Not Reproducible** — attempted but could not force the race deterministically
  - **N/A** — the finding is structural (grep-verifiable), no runtime repro needed
- When a fix ships, add `Fixed by <commit>` to the row; don't delete.

---

## Normal issues

| ID | Title | Where | Why | Fix | Reproduction |
|---|---|---|---|---|---|
| **UR.1** | Bonjour retry recursion discards freshly-stashed endpoint | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:185-249` | L195 unconditionally clears `pendingReconnectEndpoints[endpoint.name]` on every entry, including retry recursion. If an iOS peer's `NWBrowser.onAdded` fires a refreshed endpoint Y while the retry path is sleeping at L241 with a stale X, Y is stashed at L191 (guard path), then wiped at L195 when L243 recurses with X. Retry uses stale X → `connect` throws → no engine ever appended → `terminateRuntimeEngine`'s stash drain never runs → peer permanently lost until rebrowsed. | Either (a) prefer `pendingReconnectEndpoints[endpoint.name]` over the passed endpoint before recursing, and remove the L195 blanket clear (only clear after successful connect at L211); or (b) drop L195 entirely and make `terminateRuntimeEngine` / successful-connect the sole owners of stash lifecycle. | **Not Reproducible (as unit test).** `connectToBonjourEndpoint` is `private` on the `RuntimeEngineManager.shared` singleton, takes a real `RuntimeNetworkEndpoint`, and internally creates a `RuntimeEngine` that uses real `NWBrowser` / `NWConnection`. Would need either a test-only seam (injectable endpoint source, mockable `RuntimeEngine.connect`) or an end-to-end integration test driving two devices. Verify manually: flap an iOS peer during the 2/4/8s retry window and confirm the Toolbar loses it. |
| **UR.2** | Proxy server drops `objectsLoadingProgress` pushes for mirrored clients | `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift:128-131` | Wires `runtimeObjectsInImage` directly to `engine.objects(in:)`, bypassing `_serverObjectsWithProgress` (RuntimeEngine.swift:570-581) — the only site that emits `.objectsLoadingProgress` over the wire. `setupPushRelay` doesn't forward the progress message either. Multi-hop Bonjour scenario (Host C → Host B's proxy → Host A): the sidebar progress bar freezes at 0% until the full list arrives. | Route the proxy's `runtimeObjectsInImage` handler through `objectsWithProgress(in:)` and forward each `.progress(...)` event as an `.objectsLoadingProgress` push on the proxy's `connection` while accumulating the final `.completed(objects)` for the return value. Consider extracting the shared logic into a helper that both `_serverObjectsWithProgress` and the proxy handler can call. | **N/A — structural.** Verifiable by grep: `.objectsLoadingProgress` only has one producer (`_serverObjectsWithProgress` at RuntimeEngine.swift:575) and the proxy's handler bypasses it. An end-to-end integration test would require spinning up a RuntimeEngine against a real dylib (e.g. `/usr/lib/libobjc.A.dylib`), which is outside the unit-test profile of this package. Could be added as a regression test once the fix lands. |
| **UR.3** | `@unchecked Sendable` client leaks sync on `pendingHandlers` and `connectionStateCancellable` | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeLocalSocketConnection.swift:556-574` | `RuntimeLocalSocketClientConnection` is `@unchecked Sendable` and protects `isStopped` / `_isReconnecting` with `@Mutex`, but leaves `pendingHandlers` (L564) and `connectionStateCancellable` (L567) as plain `var`. The new reconnection `Task` iterates `pendingHandlers` at L706-710 concurrently with public `setMessageHandler` overloads appending at L648/L661/L673/L685/L697, and mutates `connectionStateCancellable` at L714 concurrently with `stop()` nil'ing it at L774. **Note:** this reactivates **FP.4** from `2026-04-10-rc4-review-findings.md` — the FP.4 premise ("all setMessageHandler calls happen during initial wiring before any reconnection fires") no longer holds once this PR introduces the reconnection Task. | Wrap both fields with `@Mutex`. Take a snapshot before iterating (`let handlers = pendingHandlers` inside the lock, then iterate the snapshot) to avoid holding the lock across user closures. | **Fixed (2026-04-19)** — Added `@Mutex` to both fields; `applyPendingHandlers` now snapshots inside the lock; `observeUnderlyingConnectionState` and `stop()` perform cancel+assign atomically via `_connectionStateCancellable.withLock`. TSan re-run: `testConcurrentSetMessageHandlerDuringReconnect` no longer reports "Swift access race" in `setMessageHandler<A,B>`; `testConcurrentStopDuringReconnect` no longer reports the L775 data race. Remaining TSan warnings belong to the underlying `RuntimeLocalSocketConnection` / server side and are tracked separately. |

---

## Nit issues

| ID | Title | Where | Why | Fix | Reproduction |
|---|---|---|---|---|---|
| **UR.4** | Test captures local `var` in `@Sendable` closure without synchronization | `RuntimeViewerCore/Tests/RuntimeViewerCommunicationTests/RuntimeLocalSocketConnectionTests.swift:370-399` (`testFireAndForget`) | `var receivedMessage: String?` is captured by a `@Sendable` message handler that writes it from the server's dispatch context, while the test thread reads it after only `Task.sleep(200ms)` — no happens-before. The `RuntimeViewerCommunicationTests` target pins `swiftLanguageModes: [.v5]` and has no `StrictConcurrency` / `-warnings-as-errors`, so this compiles cleanly today, but the file will fail to compile if the package ever flips to Swift 6 mode. | Wrap the value in the `private actor Counter`-style holder already used by the concurrent tests two suites below in this same file (lines 486-489). One-line conceptual change, mirrors neighboring tests. | **Structural only.** TSan under `swift test --sanitize=thread --filter testFireAndForget` does **not** flag the `receivedMessage` accesses — the single write happens on a dispatch-queue hop and the read happens after a 200ms `Task.sleep`, so TSan observes no temporal overlap. The contract violation remains real (Swift 6 would reject it, and a flakier scheduler could reorder) but no runtime repro is available in current conditions. |
| **UR.5** | `directBonjourEngines` leaks stale `ObjectIdentifier` on disconnect-during-`requestEngineList` | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:210-234` | Inner detached `Task` at L213-234 captures `runtimeEngine` strongly and unconditionally inserts `ObjectIdentifier(runtimeEngine)` into `directBonjourEngines` on the empty-descriptors (L223) and catch (L231) paths. If `terminateRuntimeEngine` already ran (peer disconnected during the await), the cleanup at L322-325 iterates `bonjourRuntimeEngines` — empty — so the id is never removed. Task keeps engine alive long enough to insert; engine is then deallocated, leaving a dangling-pointer-value id in the set. Per-disconnect bounded leak; `rebuildSections` classification is at risk if the address ever gets reused by another `RuntimeEngine`. | Gate both inserts: `if self.bonjourRuntimeEngines.contains(where: { $0 === runtimeEngine }) { ... }`. Alternatively capture `runtimeEngine` weakly in the inner Task and early-return on deallocation. | **Not Reproducible (as unit test).** Same `RuntimeEngineManager.shared` singleton constraints as UR.1. To force the race would need to block `runtimeEngine.requestEngineList()` mid-await and simultaneously flip the engine state to `.disconnected` — `RuntimeEngine` is an actor with no injection points. The leak is visible in practice by introspecting `directBonjourEngines.count` after a peer drops during engine-list discovery; easiest to validate by adding an `#log` of its size before/after and exercising the flap scenario manually. |
| **UR.6** | Shared `objectsLoadingProgressSubject` cross-delivers progress between concurrent image loads | `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift:145,301,583-593` | `objectsLoadingProgressSubject` is a single per-engine `PassthroughSubject`; `_remoteObjectsWithProgress` subscribes a sink per request, and the client-side relay at L301 forwards every inbound `.objectsLoadingProgress` unconditionally. `RuntimeObjectsLoadingProgress` (Common/RuntimeObjectsLoadingProgress.swift) carries no image path or request ID, so sinks cannot filter by request identity. Two overlapping `objectsWithProgress(in:)` calls (sidebar source switch mid-load) produce cross-delivered events; the new image's progress bar shows values that describe the old image. M6.1/M6.2 narrow the window but don't close it — the server is not cancellation-aware over the wire. | Add `imagePath: String` (or a per-request UUID) to `RuntimeObjectsLoadingProgress` and `.filter { $0.imagePath == image }` in the sink. Or key a per-request one-shot handler by UUID in the `runtimeObjectsInImage` request payload, avoiding the shared subject entirely. Either is a wire-protocol change — document as a known limitation for RC.5 unless we take the change now. | **N/A — structural.** `RuntimeObjectsLoadingProgress` payload has no `imagePath` / request ID field (confirmed by reading the struct); `PassthroughSubject.send` broadcasts to every subscriber by definition. A unit test proving "Combine broadcasts to all sinks" would not pin down the RuntimeEngine-level bug without injecting a mock `RuntimeConnection`, which is infeasible without adding a test hook to production code. Fix should land together with a test that asserts the wire payload contains a request identifier. |

---

## Reproduction summary (2026-04-17)

| ID | Status | Evidence |
|---|---|---|
| UR.1 | Not Reproducible (as unit test) | Private singleton API, real NWBrowser dependency. |
| UR.2 | N/A — structural | Grep confirms `.objectsLoadingProgress` has a single producer (`_serverObjectsWithProgress`) and the proxy handler bypasses it. |
| UR.3 | **Fixed (2026-04-19)** | `@Mutex` added to both fields; TSan re-run confirms neither race appears. See row above for details. |
| UR.4 | Structural only | TSan does not flag the `receivedMessage` accesses under the 200ms-sleep timing. Contract violation remains real (would break under Swift 6 StrictConcurrency). |
| UR.5 | Not Reproducible (as unit test) | Same singleton/actor constraints as UR.1. |
| UR.6 | N/A — structural | `RuntimeObjectsLoadingProgress` has no request-identity field; `PassthroughSubject.send` broadcasts by definition. |

---

## Planned fixes

Concrete code-level sketches derived from the review. These are proposals —
verify against the current file state before applying; keep the diff minimal.

### UR.3 — `@Mutex` wrap `pendingHandlers` and `connectionStateCancellable`

`RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeLocalSocketConnection.swift`

```swift
// L564 / L567 — mirror the existing @Mutex pattern on isStopped / isReconnecting
@Mutex private var pendingHandlers: [@Sendable (RuntimeLocalSocketConnection) -> Void] = []
@Mutex private var connectionStateCancellable: AnyCancellable?

// All 5 setMessageHandler overloads (L648/L661/L673/L685/L697):
_pendingHandlers.withLock { $0.append(setupHandler) }

// L706-710 — snapshot before iterating so user closures aren't invoked under the lock:
private func applyPendingHandlers(to connection: RuntimeLocalSocketConnection) {
    let snapshot = _pendingHandlers.withLock { $0 }
    for handler in snapshot { handler(connection) }
}

// L713-723 / L774-775 — wrap reads and writes of connectionStateCancellable:
_connectionStateCancellable.withLock { cancellable in
    cancellable?.cancel()
    cancellable = connection.statePublisher.sink { ... }
}
```

**Verification:** `swift test --sanitize=thread --filter
testConcurrentSetMessageHandlerDuringReconnect` and
`testConcurrentStopDuringReconnect` — both should stop reporting the
"Swift access race" in `setMessageHandler` and the data race at L775.

### UR.1 — Bonjour retry prefers the freshly-stashed endpoint

`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:185-249`

Two coupled changes:

1. Delete L195's blanket `pendingReconnectEndpoints.removeValue(forKey:)`.
2. Clear the stash **only after a successful connect**, and in the retry
   path prefer any entry that was stashed during the sleep window.

```swift
// success path — after appendBonjourRuntimeEngine
pendingReconnectEndpoints.removeValue(forKey: endpoint.name)

// catch / retry path
if attempt < Self.maxRetryAttempts {
    try? await Task.sleep(nanoseconds: delay)
    knownBonjourEndpointNames.remove(endpoint.name)
    let nextEndpoint = pendingReconnectEndpoints.removeValue(forKey: endpoint.name) ?? endpoint
    await connectToBonjourEndpoint(nextEndpoint, attempt: attempt + 1)
}
```

### UR.2 — Proxy routes through progress-forwarding helper

Extract a shared helper on `RuntimeEngine` and call it from both
`_serverObjectsWithProgress` (RuntimeEngine.swift:570-581) and the proxy's
`runtimeObjectsInImage` handler (RuntimeEngineProxyServer.swift:128-131):

```swift
// RuntimeEngine.swift — new package-internal helper
func collectObjectsWhileForwardingProgress(in image: String, to connection: RuntimeConnection) async throws -> [RuntimeObject] {
    var result: [RuntimeObject] = []
    for try await event in objectsWithProgress(in: image) {
        switch event {
        case .progress(let progress):
            try? await connection.sendMessage(name: CommandNames.objectsLoadingProgress.commandName, request: progress)
        case .completed(let objects):
            result = objects
        }
    }
    return result
}

// RuntimeEngineProxyServer.swift:128-131 — replace direct engine.objects(in:)
connection.setMessageHandler(name: RuntimeEngine.CommandNames.runtimeObjectsInImage.commandName) {
    [engine, weak connection] (image: String) -> [RuntimeObject] in
    guard let connection else { return [] }
    return try await engine.collectObjectsWhileForwardingProgress(in: image, to: connection)
}
```

`_serverObjectsWithProgress` becomes a one-liner that delegates to the
helper, eliminating duplication.

### UR.4 — Swap local `var` for generic actor holder in `testFireAndForget`

`RuntimeViewerCore/Tests/RuntimeViewerCommunicationTests/RuntimeLocalSocketConnectionTests.swift:370-399`

```swift
private actor Box<T: Sendable> {
    private(set) var value: T
    init(_ initial: T) { value = initial }
    func set(_ new: T) { value = new }
}

@Test("Fire-and-forget message with no response")
func testFireAndForget() async throws {
    // ...
    let received = Box<String?>(nil)
    server.setMessageHandler(name: "notify") { (message: String) in
        await received.set(message)
    }
    // ...
    #expect(await received.value == "Hello Socket")
}
```

Place `Box` alongside the existing `actor Counter` at
`RuntimeLocalSocketConnectionTests.swift:486-489`, or promote it to a
file-scope helper if a second use-site appears.

### UR.5 — Gate `directBonjourEngines.insert` on ongoing ownership

`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:213-234`

```swift
Task { [weak self] in
    guard let self else { return }
    do {
        let descriptors = try await runtimeEngine.requestEngineList()
        if descriptors.isEmpty {
            guard self.bonjourRuntimeEngines.contains(where: { $0 === runtimeEngine }) else { return }
            self.directBonjourEngines.insert(ObjectIdentifier(runtimeEngine))
            self.rebuildSections()
        } else {
            self.handleEngineListChanged(descriptors, from: runtimeEngine)
        }
    } catch {
        guard self.bonjourRuntimeEngines.contains(where: { $0 === runtimeEngine }) else { return }
        self.directBonjourEngines.insert(ObjectIdentifier(runtimeEngine))
        self.rebuildSections()
    }
}
```

### UR.6 — Tag progress with `imagePath` and filter at the sink (deferred)

Wire-protocol change; **defer beyond RC.5** unless we're already cutting a
minor that bumps the protocol.

```swift
// Common/RuntimeObjectsLoadingProgress.swift — add an identifier
public struct RuntimeObjectsLoadingProgress: Sendable, Codable {
    public let imagePath: String   // new; populated by the server
    public let phase: Phase
    public let itemDescription: String
    public let currentCount: Int
    public let totalCount: Int
}

// RuntimeEngine.swift _serverObjectsWithProgress — stamp the image path
case .progress(let progress):
    let tagged = RuntimeObjectsLoadingProgress(imagePath: image, ...)
    try? await connection?.sendMessage(name: .objectsLoadingProgress, request: tagged)

// _remoteObjectsWithProgress — filter by request identity
let cancellable = objectsLoadingProgressSubject
    .filter { $0.imagePath == image }
    .sink { progress in continuation.yield(.progress(progress)) }
```

**Compatibility note:** bumps the wire schema — a 2.0.x client talking to
a 2.0.0-RC.x server won't know about `imagePath`. Either require matched
versions (already the case inside a single install) or make the field
optional with a migration path.

---

## Relationship to RC.4 findings

- **UR.3 supersedes FP.4.** FP.4 in `2026-04-10-rc4-review-findings.md` was kept as a false positive on the premise that `setMessageHandler` only runs during initial wiring. This PR introduces a reconnection `Task` that iterates `pendingHandlers` concurrently, invalidating the premise. UR.3 is tracked here as the authoritative record; the FP.4 row should stay for history but add a forward-reference to UR.3 when convenient.
- **UR.2 is a cross-slice interaction.** Slice 3's `RuntimeEngineProxyServer` and Slice 6's progress-streaming protocol are both new in v2.0.0. Neither was wrong on its own; the interaction between them was not covered by the per-slice reviews. `Documentations/KnownIssues/2026-04-10-rc4-review-findings.md` M6.1 (onTermination) and M6.7 (try? swallows) do not cover this path.
- **UR.6 is adjacent to M6.1/M6.2.** The three together (producer task cancellation, VM reload serialization, request-identity in progress payload) constitute the full story for sidebar source switches mid-load. UR.6 is the only one that requires a wire-protocol change, so it is the practical candidate for deferring to a later release.
