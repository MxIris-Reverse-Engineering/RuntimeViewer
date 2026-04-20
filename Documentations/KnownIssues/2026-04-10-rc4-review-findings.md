# v2.0.0-RC.4 Pre-Release Review Findings

**Review date:** 2026-04-10
**Branch reviewed:** `feature/socket-injected-endpoint-reconnection` @ `04ed410`
**Method:** 9 parallel `code-reviewer` agents, one per feature slice
**Scope:** ~11,500 LOC / 100+ commits since `v2.0.0-RC.3`

## Status at a glance

| Class | Count | Notes |
|---|---:|---|
| Blockers (original) | 16 | Reduced to **3** after verification; 13 were false positives or over-severe classifications |
| Blockers **fixed** | **3** | See below |
| Majors (tracked here) | 44 | Not ship-blocking, prioritized list below |
| Minors (tracked here) | 32 | Polish, style, and docs |
| False positives (documented) | 6 | Kept so the same paths aren't re-flagged |

## Fixed Blockers

These three were the only issues that actually blocked shipping. They were
fixed in-branch before this document was written.

| ID | Commit | Title |
|---|---|---|
| B3 | `af541c7` | `fix: drain pending requests when message channel stops receiving` |
| B2 | `90f5a70` | `fix: only reinstall helper on explicit version mismatch, not on transient errors` |
| B1 | `5123311` | `fix: reconcile mirrored engines per-source so multi-host updates don't wipe peers` |

---

## How to use this document

- Pick an item by ID. Read **Why** to understand the bug, then **Fix** for
  the suggested direction. Open the referenced file at the referenced lines
  before writing any code — files drift.
- When you ship a fix, add a "Fixed by `<commit>`" note in the row and move
  it to the bottom of its section; don't delete.
- If a row turns out to also be a false positive, don't delete either — flip
  it to the **False positives** section with an explanation.

---

## Major issues

### Slice 2 — Networking (HostInfo / Bonjour / iOS real device support)

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **M2.1** | `RuntimeMessageChannel.send` holds semaphore across `await writer` | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeMessageChannel.swift:265-306` | The send semaphore is held for the duration of the network write. A hang at the transport layer blocks every subsequent send on the channel, not just this one request. | Narrow the semaphore scope to protect only state mutation. Either drop the semaphore entirely (underlying transports are already serial per their own queue) or use `defer { signal() }` immediately after staging the bytes. |
| **M2.2** | `localHostName` static cache | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeNetwork.swift:55-92` | `static let localHostName` resolves once at class load. On iOS with no Wi-Fi at launch, the fallback returns a generic "iPhone" and the cache is never refreshed when connectivity appears later. | Change to a computed static accessor, re-read at advertise time. Or invalidate the cache when the system reports reachability changes. |
| **M2.3** | Bonjour `RuntimeSource.identifier` mismatch between client and server | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeSource.swift:198-204` | Client uses `endpoint.name`, server uses `id.rawValue`. Two devices with the same display name (both "iPhone") collide; the disconnect cleanup compares by identifier and can kick the wrong engine off. | Client-side: use `endpoint.instanceID` as the stable part of the identifier; fall back to `"\(name)@\(endpoint.debugDescription)"` if missing. |
| **M2.4** | `waitingTimeoutWork` / `isStarted` unsynchronized | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeNetworkConnection.swift:69-70,107-144` | `handleStateChange` runs on the connection queue while `stop()` may be called from `.main` or from `handleStateChange` itself via `stop(with:)`. Reads and writes to both plain vars race. | Wrap in `@Mutex` or enforce single-threaded access by dispatching `stop()` onto the connection queue. |
| **M2.5** | `RuntimeStdioConnection` has no max-buffer protection | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeStdioConnection.swift` | A malicious or buggy peer that never sends `\nOK` causes the receive buffer to grow unbounded until the process OOMs. | In the receive loop, check `receivingData.count > maxBufferSize` (e.g. 32 MB) and if exceeded, `stop(with: .protocolError("buffer overflow"))`. |
| **M2.6** | iOS TCP keepalive 2s/2s/3 too aggressive | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeNetworkConnection.swift:83-85` | Dead peer detected after ~8s. On iOS during screen-lock NEHotspot transitions, this flags a healthy connection as dead. | Raise to at least 5s/5s/3 on iOS, or gate by platform. |
| **M2.7** | `startListeningWithRetry` 20s `asyncAfter` on main queue can cancel a later listener | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeNetworkConnection.swift:387-415,442-454` | The timeout captures `listener` by reference. If `self.listener` is replaced between the schedule and the fire, the timeout may cancel the newer instance during a subsequent attempt. | Capture the per-iteration `newListener` locally AND check `self.listener === newListener` before cancelling inside the timeout closure. |
| **M2.8** | `RuntimeMessageChannel.processReceivedData` reads `receivedDataContinuation` outside the mutex | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeMessageChannel.swift:202-234` | `hasContinuation` is computed without `withLock`, and the later `yield` is also outside. Racing with `finishReceiving` is benign (yield-after-finish is a no-op), but the doc comment claims "called from a locked context" which is no longer true. | Either wrap the yield in `_receivedDataContinuation.withLock` or update the doc comment to document the non-locked access. |

### Slice 3 — Remote engine mirroring / `RuntimeEngineProxyServer`

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **M3.1** | `RuntimeEngineManager` not `@MainActor`-isolated | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift` (whole class) | `@Published` state (`bonjourRuntimeEngines`, `mirroredEngines`, `runtimeEngineSections`) plus `engineIconCache` / `proxyServers` dictionaries mutated from multiple Task contexts without isolation. UI bindings then fire on unknown threads. | Annotate the whole class `@MainActor`, wrap off-main work in `Task.detached` or `await MainActor.run` where necessary. This simultaneously addresses parts of M3.3 and M4.1. |
| **M3.2** | `updateProxyServers` creates proxies for mirrored engines | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:530-582` | The loop iterates all `runtimeEngines`, which now includes `mirroredEngines.values`. Host A spins up a new `RuntimeEngineProxyServer` (NWListener + keepalive timer) for every engine it mirrored from B and re-advertises them downstream. Wasteful network cost and N² proxy count. | Guard with `guard engine.hostInfo.hostID == RuntimeNetworkBonjour.localInstanceID else { continue }` before creating a proxy. Optionally also in `buildEngineDescriptors` if re-advertisement is undesirable. |
| **M3.3** | `terminateRuntimeEngine` doesn't scan `mirroredEngines` | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:289-308` | Only `system`, `attached`, and `bonjour` arrays are scrubbed. A mirrored engine whose directTCP connection drops stays in `mirroredEngines` until the upstream Bonjour connection also disconnects, leaving a stale entry in the Toolbar. **Note:** partially addressed by B1's `cleanupMirroredEnginesOnDisconnect`, but `terminateRuntimeEngine(for:)` itself still doesn't know about the mirror dict. | Either extend the function to also filter `mirroredEngines`, or have all callers route through the new cleanup helper. |
| **M3.4** | `RuntimeEngineProxyServer` is single-shot | `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift:36-71,222-251` | `start()` calls `communicator.connect(...)` once and stores the single `connection`. When that client disconnects, the stored publisher subscriptions reference a dead connection and further events become no-ops; nothing re-creates the proxy. | Either mirror `RuntimeDirectTCPServerConnection.restartListening` behavior, or have `RuntimeEngineManager.updateProxyServers` observe the proxy's connection state and tear down / recreate on disconnect. |
| **M3.5** | `hostInfo.hostID` falls back to Bonjour display name | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:185-194` | `HostInfo(hostID: endpoint.instanceID ?? endpoint.name, ...)`. When the TXT record lacks `rv-instance-id` (older peer, TXT parse failure), two devices with the same display name collide and disconnect cleanup mis-targets. | Reject endpoints without a parseable instanceID, or compute a locally-stable random ID keyed by `(name, first-seen-timestamp)` and persist it. |
| **M3.6** | `RuntimeEngineProxyServer` `.info` log spam | `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift:43-106,222-250` | ~15 `.info` sites including per-push relay events (`[PROXY id] relaying imageNodes (N nodes)`) and per-send success logs. Under load this dumps thousands of lines per second into the unified log. | Downgrade relay/send-ok/per-state lines to `.debug`; keep `start`, `stop`, and error paths as `.info`/`.error`. |
| **M3.7** | `NSRunningApplication` / `NSWorkspace` called off main thread | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:440-448` | `cacheLocalAppIcon` is invoked from detached Tasks (e.g. `reconnectInjectedSocketEngines`), but `NSRunningApplication(processIdentifier:)` and `NSWorkspace.shared.icon(forFile:)` are main-thread APIs. | Mark `cacheLocalAppIcon` `@MainActor`, or wrap the call site in `await MainActor.run`. Subsumed by M3.1 if the whole class becomes `@MainActor`. |

### Slice 4 — XPC injected endpoint reconnection

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **M4.1** | `RuntimeViewerService` registry dictionaries unsynchronized | `RuntimeViewerPackages/Sources/RuntimeViewerService/RuntimeViewerService.swift:28-147` | `injectedEndpointsByPID` and `processMonitorSources` are plain vars. SwiftyXPC delivers handler messages on its internal queue while `DispatchSource.makeProcessSource(..., queue: .main)` runs the exit handler on `.main`. Concurrent writes race. | Convert the class to `actor`, or serialize mutations through a single dispatch queue, or wrap the two dicts in `Mutex`. |
| **M4.2** | Mach Service registration only on first connect | `RuntimeViewerServer/RuntimeViewerServer/RuntimeViewerServer.swift:60-70` | If the registration `sendMessage` fails at the moment the daemon is unreachable, the injected process never retries. The endpoint is lost until the process is re-injected. | Retry on engine state transition to `.connected`, or on a timer until the first successful registration. |
| **M4.3** | `ClientReconnected` handler can flap state back to `.disconnected` | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeXPCConnection.swift:361-375` + `:141-144` | Handler does `self.connection?.cancel(); self.connection = newConnection; self.stateSubject.send(.connected)`. The old connection's `errorHandler` fires asynchronously after `cancel()` and calls `handleClientOrServerConnectionError`, which sends `.disconnected(...)` to the same `stateSubject`. If that fires after `.connected`, the engine flaps to `.disconnected`. | Before `cancel()`, reset `self.connection?.errorHandler = { _, _ in }`. Or give the error handler a closure-captured identity check so it only reports for the current connection. |
| **M4.4** | `KeepAlive=true` is an unconditional behavior change | `RuntimeViewerUsingAppKit/com.mxiris.runtimeviewer.service.plist` + `dev.mxiris.runtimeviewer.service.plist` | The helper daemon previously idled out after a quiet period; now it runs indefinitely and respawns after any crash. Users can't quit it via normal means. | At minimum document in release notes. Ideally use a conditional `{ SuccessfulExit = false }` so it only restarts on crash, with the in-memory registry lost on voluntary exit (users trigger auto re-registration by reopening the main app). |
| **M4.5** | Stale endpoint cleanup is fire-and-forget on first connect failure | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:322-355` | A single transient `connect()` failure during `reconnectInjectedXPCEngines` triggers `runtimeInjectClient.removeInjectedEndpoint(pid:)` immediately. The entry is evicted even if the process is healthy. | Gate the `remove` call on `kill(pid, 0) != 0 && errno != EPERM` — only evict if the process is actually dead. |
| **M4.6** | XPC listener accepts any caller (`codeSigningRequirement: nil`) | `RuntimeViewerPackages/Sources/RuntimeViewerService/RuntimeViewerService.swift:34` + all handlers that accept caller-supplied PIDs | An unprivileged local process can connect to the helper Mach service and register fake endpoints (or evict real ones) by supplying any PID and a controlled `XPCEndpoint`. On Host restart, the Host will direct-connect to the attacker's listener and exchange `ClientReconnected` (full trust transfer of the Host's listener). **Note:** this is an existing pattern across all handlers in the file, not new to this slice — treat as a broader hardening pass. | Set `codeSigningRequirement: "identifier com.mxiris.runtimeviewer.X and anchor apple generic and ..."` at listener creation. Inside each handler, also verify `audit_token_to_pid(connection.auditToken) == request.pid` for anything that takes a PID parameter. |
| **M4.7** | PID recycle window between `register` and `monitor` | `RuntimeViewerPackages/Sources/RuntimeViewerService/RuntimeViewerService.swift:112-147` | Between the client's `sendMessage(RegisterInjectedEndpointRequest)` and `DispatchSource.makeProcessSource`, the original process can die and the PID can be reused. The dispatch source then watches the wrong process and the stale endpoint is never cleaned up. | Take the audit-token PID at registration time as the canonical identity; verify it still matches before creating the source. Consider keying by `(pid, auditToken-cdhash)` for stronger identity. |

### Slice 5 — Socket injected endpoint reconnection

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **M5.1** | `aliveRecords` only appended in the `connect()` success branch | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:359-398` | If `kill(pid, 0)` says the process is alive but `runtimeEngine.connect()` throws (server bind race, port in TIME_WAIT, helper slow), the record is not appended to `aliveRecords`. `saveInjectedSocketEndpointRecords(aliveRecords)` then writes a list that excludes this still-live process. Next launch forgets about it. | Append to `aliveRecords` as soon as the liveness check passes; the connect call is a re-attachment attempt, not a persistence gate. |
| **M5.2** | `errno` not cleared before `kill(pid, 0)` | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Utils/RuntimeEngineManager.swift:371` | `kill() == 0 || errno == EPERM` relies on `errno` being fresh. Works today because Darwin's `kill(2)` always sets errno on failure, but any future intermediate libc call between kill and the read (or a log formatter reaching into errno indirectly) silently breaks the check. | Set `errno = 0` immediately before `kill(...)`. Consider a more explicit switch on errno values (`ESRCH` → dead, `EPERM` → alive-but-unreachable, default → treat as alive to be safe). |
| **M5.3** | Reconnect loop has no backoff / retry cap / jitter | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeLocalSocketConnection.swift:573-574,737-765` | Fixed 500 ms sleep forever. If the target process is permanently gone, we retry for the lifetime of the injected dylib, logging every attempt. | Exponential backoff 500 ms → 30 s cap, add jitter, terminate with `.disconnected` after N attempts or T total seconds. |
| **M5.4** | `close(fd)` called without first `shutdown()` | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeLocalSocketConnection.swift:179-205` | On Darwin, closing a descriptor while another thread is blocked on `recv()`/`send()` is unsafe: the fd can be immediately reused by a different syscall in another thread, and the stale recv/send operates on the wrong resource. | Call `shutdown(fd, SHUT_RDWR)` first to wake the blocked syscalls with EOF/error, wait for the read queue to drain (or sleep briefly), then `close(fd)`. |
| **M5.5** | `observeUnderlyingConnectionState` only forwards `.isDisconnected` | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeLocalSocketConnection.swift:709-720` | The sink ignores `.connected` transitions and relies on the explicit `ownStateSubject.send(.connected)` after `try connection.start()`. Asymmetric with the server-side pattern. | Forward `.connected` as well; remove the explicit send. This makes reconnect observability consistent. |

### Slice 6 — Sidebar loading progress

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **M6.1** | `objectsWithProgress` producer Task has no `continuation.onTermination` | `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift:530-551` | The stream builder spawns a `Task` but does not set `onTermination`. When the consumer cancels (user switches source mid-load, `Task.cancel()`), the producer keeps running through the whole binary; yields become no-ops but CPU is wasted and remote requests still hit the wire. | Capture the task handle and set `continuation.onTermination = { [task] _ in task.cancel() }`. Inside producers, periodically `try Task.checkCancellation()`. |
| **M6.2** | `SidebarRuntimeObjectViewModel` concurrent reloads not cancelled or serialized | `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectViewModel.swift:36-54,164-216` | The `reloadDataPublisher` subscription and the initial `Task` both call `reloadData()` without holding a handle. Rapid source changes spawn overlapping loaders that write the same `@Observed loadingProgress` from the main actor; progress bounces, the final `self.nodes = …` is last-write-wins. | Add `private var reloadTask: Task<Void, Error>?`. At the top of `reloadData()`, cancel the prior task and replace. Propagate cancellation into the stream iteration via `try Task.checkCancellation()`. |
| **M6.3** | Two declared progress phases are never emitted | `RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectsLoadingProgress.swift:5,18,63,76` + producers | `.preparingObjCSection` (0.00–0.02) and `.buildingObjects` (0.90–1.00) are declared, have reserved ranges, and the test `progressRangesCoverFullSpectrum` asserts the full spectrum. But grep confirms no producer emits them — the VM manually fakes "Building list…" at 0.95. | Either emit these phases from `_localObjectsWithProgress` at the appropriate entry/exit points, or remove them from the enum and rebase the reserved ranges. |
| **M6.4** | `ProgressEventHandler` / VM burns main thread on high-throughput events | `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift:109-182` + `SidebarRuntimeObjectViewModel.swift:182-203` | `incrementAndYield` locks on every event; `buildRuntimeObjectsStream` iteration wraps every progress in `await MainActor.run { … }`. For large Swift indexing, tens of thousands of events serialize through one hop each. | Throttle: aggregate on a non-main actor and push at ~60 Hz (`.sample(.milliseconds(16))` equivalent), or drop events where `phase` hasn't changed and `currentCount % 64 != 0`. |
| **M6.5** | `StatefulOutlineView` reentrancy guard is a plain `Bool` | `RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/StatefulOutlineView.swift:118-135` | The flag prevents the reported crash (nested `reloadData()` from AppKit) but silently drops the second call. Combined with the `DispatchQueue.main.async` fallback in `endFiltering()`, the guard can leave `filteringState == .pendingRestore` stuck forever. | Replace with a state enum (`.idle / .reloading / .reloadingWithPending`). On nested reload, set `.reloadingWithPending`; when the outer reload finishes, check the flag and re-reload once. |
| **M6.6** | `SidebarRuntimeObjectListViewModel.buildRuntimeObjectsStream` wraps the engine stream redundantly | `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectListViewModel.swift:34-52` | An `AsyncThrowingStream` builder wraps `runtimeEngine.objectsWithProgress(in: imagePath)` with another Task hop and loses the cancellation link end-to-end. | Delete the wrapper; just `return runtimeEngine.objectsWithProgress(in: imagePath)`. |
| **M6.7** | Server-side `_serverObjectsWithProgress` swallows send failures with `try?` | `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift:570-581` | `try? await connection?.sendMessage(name: .objectsLoadingProgress, ...)` silently drops any network error. If the client disconnected mid-load, the server computes to completion with no one listening. | `try` with a catch that `break`s the loop (or aborts the stream with a RequestError). |

### Slice 7 — SwitchSource toolbar item

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **M7.1** | VC has 43 lines of business logic | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift:151-195` | Menu construction, icon resolution delegation, `AnyHashable` selection lookup, disabled-placeholder insertion all live in the VC. Per CLAUDE.md MVVM-C rules, the VC should only bind. | Expose a projected `Driver<[SwitchSourceMenuItem]>` from `MainViewModel` where each item already carries `(title, image, isEnabled, isSelected, representedObject)`. VC just maps that to `NSMenu`. |
| **M7.2** | Diamond dependency in `Driver.combineLatest(sections, state)` | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift:152` + `MainViewModel.swift:231-258` | `switchSourceState` is derived from `runtimeEngineSections`. Combining them at the VC level fires the closure twice on every sections update, first with a stale state. | Expose a single merged `Driver<(sections, state)>` from the VM, or fold `sections` into `SwitchSourceState` so only one output is needed. |
| **M7.3** | `SwitchSourceState.==` compares `image` with `===` | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift:31-36` | `resolveEngineIcon` returns fresh `NSImage.symbol(name:)` instances on some branches. Identity compare always fails, the Driver never stabilizes, and the menu rebuilds on every upstream tick. | Drop `image` from equality; use the stable `engineID` or hash. |
| **M7.4** | `.map` closure mutates `cachedSelectedEngineName` / `cachedSelectedEngineImage` | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift:231-258` | Side effects inside `.map` are non-idempotent: a second subscriber would double-write. Works today only because there's one subscriber. | Move cache writes to a dedicated `.do(onNext:)` before the `.map`, or into the `switchSource` input handler. |
| **M7.5** | `selectedEngineIdentifier` default hard-coded to `RuntimeEngine.local.engineID` | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift:81` | Works today because `MainCoordinator` starts with `.main(.local)`, but there's no invariant enforcing it. | Initialize from `documentState.runtimeEngine.engineID` in `init`. |
| **M7.6** | Shared `NSImage.size` mutated in-place | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift:170,181` | `menuItem.image?.size = NSSize(...)` mutates the NSImage returned by `engineIconCache`, which may be shared with sidebar cells and other toolbar items. Not a crash, but can cause visual inconsistency. | `image.copy() as? NSImage`, set size on the copy, assign. Or add a `resized(to:)` helper. |

### Slice 8 — Transformers + Settings UI refactor

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **M8.1** | `RuntimeObject.withImagePath` drops the new `properties` OptionSet | `RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObject.swift:38-40` | `@Init(default: [])` lets `withImagePath` re-construct the object with an empty `properties` when the arg is omitted. Any `isGeneric` flag is silently lost when a Swift object is re-pathed. | Pass `properties: properties` explicitly in the init call inside `withImagePath`. |
| **M8.2** | `NavigationSplitView` selected page not persisted | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift:52-74` | `selectedPage` is `@State`, so Settings always reopens on General. SettingsKit previously restored the last-selected pane. | Switch to `@AppStorage("settings.selectedPage")` with a default of `.general`. |
| **M8.3** | `titlebarAppearsTransparent` removed without explanation | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsWindowController.swift:34-43` | The Settings window titlebar now renders differently (especially in dark mode). | Confirm with the designer. If unintentional, restore `contentWindow.titlebarAppearsTransparent = true`. |
| **M8.4** | `MCPSettingsView` port field has no range validation | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/MCPSettingsView.swift:28-35` | User can type `0` or `>65535`; the `UInt16` formatter silently wraps or rejects without feedback. | `.onChange` clamp to 1…65535, or use a `.numericField(range:)` wrapper. |
| **M8.5** | `MachOImage+AddressFormatting` doesn't strip arm64e PAC | `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/MachOImage+AddressFormatting.swift:13` | If any caller passes a raw pointer that still carries PAC bits, the subtraction `value - baseAddress` yields garbage. The ObjC runtime typically strips IMPs before handing them out, but this is a fragile precondition. | At minimum document the precondition; ideally call `ptrauth_strip` (or the equivalent C helper) at the top of the formatting function. |

### Slice 9 — Helper service version check + miscellaneous

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **M9.1** | `Task.sleep(.seconds(1))` magic delay originally undocumented | `RuntimeViewerPackages/Sources/RuntimeViewerHelperClient/HelperServiceManager.swift:302` | **Partially addressed by B2's fix** (added a comment explaining the SMAppService bookkeeping workaround), but the underlying brittleness remains: a fixed delay is not a proper gate. | Poll `daemon.status == .notRegistered` with a short wait in between, with a 3–5s total budget. Remove the fixed sleep. |
| **M9.2** | Version string is a single `"1.0.0"` with no build number | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeRequestResponse.swift:12` | A Debug build with the same declared `"1.0.0"` doesn't trigger reinstall even though the binary differs. Development iteration on the helper is awkward. | Compose the version from `RuntimeViewerServiceVersion + "+" + Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")`, or use git SHA for Debug builds. |
| **M9.3** | Reinstall alert can overlap with SMAppService authorization dialog | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift:85-104` | After a successful reinstall, the user sees the system authorization prompt; then the app shows its own "please restart" alert on top. | Defer the alert until after `daemon.status == .enabled` is observed, or skip it entirely when the reinstall completed cleanly without user interaction. |
| **M9.4** | C++ template filename not truncated | `RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObject+Export.swift:5` | The sanitizer handles special characters but not length. A long template name (e.g. `std::unordered_map<...>` 600+ chars) exceeds APFS's 255-byte filename limit and the write throws. | Truncate to ~200 bytes of safe characters and append a short stable hash suffix (e.g. first 8 chars of SHA256). |
| **M9.5** | `RuntimeInterfaceExportWriter.WriteResult.failedItems` produced but never consumed | `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportWriter.swift:25-67` | Failures silently vanish; there is no UI that reads the `failedItems` array. | Return the result to the exporting ViewModel and surface failures in an alert / summary sheet at the end of export. |
| **M9.6** | `FileOperationRequest` `.write` branch lacks parent-directory check | `RuntimeViewerPackages/Sources/RuntimeViewerService/RuntimeViewerService.swift:97-98` | The `.copy` branch was fixed to ensure the parent directory exists, but the `.write` branch still has the same potential failure. | Mirror the `.copy` fix: `if !fileManager.fileExists(atPath: url.deletingLastPathComponent().path) { try fileManager.createDirectory(... withIntermediateDirectories: true) }` before the `data.write`. |

---

## Minor issues (cross-cutting and per-slice)

### Documentation / release notes

| ID | Item | Fix |
|---|---|---|
| MN.1 | `@Loggable` macro migration silently renames log subsystems from hardcoded `com.mxiris.runtimeviewer.*` to `Bundle.xxx.bundleIdentifier`. | Add to `Changelogs/v2.0.0-RC.4.md` so downstream log filters can update. |
| MN.2 | `RuntimeViewer.xcworkspace` (dev) and `RuntimeViewer-Distribution.xcworkspace` (CI/release) now coexist with divergent sibling package references. | Add a one-paragraph note to `CLAUDE.md` explaining which workspace to edit for what purpose. |

### Style / consistency

| ID | Item | Fix |
|---|---|---|
| MN.3 | Mixed `Self.logger.info(...)` and `#log(.info, ...)` usage inside the same file (RuntimeEngineManager had 6 sites of the former). | One-off sweep to standardize on `#log(...)`. |
| MN.4 | `#log(.error,"…")` missing space after the comma is pervasive. | Format sweep; low priority. |
| MN.5 | Hex formatting in `Transformer+SwiftVTableOffset` and `Transformer+SwiftMemberAddress` is duplicated. | Extract a private extension on `Int` or a free function in the `Transformer` namespace. |

### Test gaps

| ID | Item | Fix |
|---|---|---|
| MN.6 | No tests for `RuntimeNetworkServerConnection` restart / multi-path behaviour (highest-risk code in slice 2). | Add at least: (a) stop-and-restart listener, new client connects, sends succeed; (b) simulated multi-path accept of duplicate connections. |
| MN.7 | No reconnection-scenario tests for `RuntimeLocalSocketClientConnection` (the feature added in this slice). | Add: (a) kill server mid-session, verify client reconnects and subsequent requests succeed; (b) pending `sendRequest` during disconnect resumes with error (this now passes thanks to B3); (c) handler registered before first connect is still installed after reconnect. |
| MN.8 | No integration test for `objectsWithProgress` cancellation / stream termination. | Mock a section factory, cancel the consumer, verify the producer's inner `Task` cancels and `onTermination` fires. Will depend on M6.1 being implemented. |
| MN.9 | `RequestTests` has no coverage for `RegisterInjectedEndpointRequest` (because `SwiftyXPC.XPCEndpoint` isn't trivially JSON-roundtrippable). | Add an inline comment documenting why the request is intentionally skipped. |
| MN.10 | `RuntimeObjectsLoadingProgressTests` doesn't cover `overallFraction` when `totalCount < currentCount` (clamp behavior) or `currentCount == 0, totalCount > 0`. | Add a parameterized regression test over phase boundaries asserting `0 ≤ overallFraction ≤ 1`. |

### Codable / protocol edge cases

| ID | Item | Fix |
|---|---|---|
| MN.11 | `HostInfo` / `RemoteEngineDescriptor` / `DeviceMetadata` Codable fallback decodes `metadata` as `?? .current` — this injects *our* metadata when a peer sends a payload without it. | Make `metadata` an `Optional` and require callers to handle `nil` explicitly. |
| MN.12 | `DeviceMetadata._readModelIdentifier` returns the Mac model on Catalyst instead of the iPad-compatible ID. | Special-case Catalyst: return `UIDevice.current.model` or similar when `ProcessInfo.processInfo.isiOSAppOnMac`. |
| MN.13 | `RuntimeNetworkEndpoint.==` excludes `instanceID` from equality. Reinstalled app with a new UUID but same service name compares equal. | Include `instanceID` in equality; callers can still do name-only matching via a separate helper. |
| MN.14 | `public import Foundation` usage is inconsistent across request files (some use it, some don't). | Sweep: either all public or all private, consistently. |
| MN.15 | `FetchAllInjectedEndpointsRequest.swift` uses `import Foundation` while siblings use `public import Foundation`. | Same as MN.14. |

### Dead code / cleanup

| ID | Item | Fix |
|---|---|---|
| MN.16 | `OSLogClient` dependency is commented out in `RuntimeViewerCore/Package.swift` rather than removed. | Delete the commented-out block; the commit message for B2 already mentioned it as "temporary". |
| MN.17 | `NavigationSplitView` icons use `SettingsIcon(symbol: page.systemImage, color: .clear)` but other places use colored icons. | Verify intentional; if so, add a `// .clear = flat style` comment. |
| MN.18 | `SettingsWindowController` removed `titlebarAppearsTransparent = true`. | Duplicate of M8.3, listed for cross-reference. |

### Misc low-priority

| ID | Item | Where | Fix |
|---|---|---|---|
| MN.19 | `AppDelegate.swift:15-18` fire-and-forget `DispatchQueue.global().async { _ = RuntimeEngine.local }`. | `RuntimeViewerUsingUIKit/App/AppDelegate.swift` | Add error handling or at minimum `#log(.error, ...)` on failure. |
| MN.20 | `listenerRetryDelay` declared as `UInt64` nanoseconds. | `RuntimeNetworkConnection.swift:361` | Consider switching to `Duration` (Swift 5.9+) for readability. |
| MN.21 | `TransformerSettingsView.swift` uses `DispatchQueue.main.async { self.height = ... }` inside `makeNSView`/`updateNSView`. | `RuntimeViewerSettingsUI/Components/TransformerSettingsView.swift:423-438` | Compute inline or use `Task { @MainActor in ... }`. |
| MN.22 | `CopyableTokenChip` uses `DispatchQueue.main.asyncAfter` with no cancellation; rapid clicks stack timers. | `TransformerSettingsView.swift:457-490` | Use a `Task` handle stored in `@State` and cancel on re-click. |
| MN.23 | `loadInjectedSocketEndpointRecords` silently swallows JSON decode errors. | `RuntimeEngineManager.swift:84-107` | Add `#log(.error, ...)` so a corrupted file at least leaves a breadcrumb. |
| MN.24 | `"(Disconnected)"` string is hardcoded English. | `MainViewModel.swift:252` | Move to a localizable constant alongside other toolbar strings. |
| MN.25 | `"Labeled\nTemplate"` hard-codes a line break. | `TransformerSettingsView.swift:594` | Single line with `.multilineTextAlignment(.trailing)`. |
| MN.26 | `Templates.all` does not include `Templates.standardLabeled` / `allLabeled`. | `Transformer+SwiftVTableOffset.swift:125-136` | Add a clarifying comment or rename to `allUnlabeled`. |
| MN.27 | `logEntry.subsystem.contains("RuntimeViewer")` is a loose match. | `AppDelegate.swift:71` | Use `hasPrefix("com.")` + explicit bundle id check. |
| MN.28 | Proxy `Task.detached { [weak self] ... }` captures `proxy` strongly. | `RuntimeEngineManager.swift:554-580` | Adjust the capture so a mid-start proxy whose manager has been deallocated can exit early. |
| MN.29 | `guard let proxy = proxyServers[localID] else { continue }` silently drops engines whose proxy isn't ready. | `RuntimeEngineManager.swift:466-467` | Queue a pending list and retry after proxy-ready; or document the race explicitly. |
| MN.30 | `RuntimeSource+.swift:24` `.directTCP` uses the generic `.network` SF symbol even when `resolveEngineIcon` already has a device icon. | `RuntimeSource+.swift:24` | Prefer the engine icon if cached; fall back to `.network`. |
| MN.31 | `Driver`-source `MainViewModel.swift:236` fallback title `"RuntimeViewer"` is dead code (VM is retained by Coordinator). | `MainViewModel.swift:236` | Delete the branch. |
| MN.32 | `AnyHashable(engine.engineID)` wrapping `String` is unnecessary. | `MainWindowController.swift:171,189` | Assign `String` directly. |

---

## False positives (kept for bookkeeping)

These were flagged as Blockers by the review agents but were verified as
non-issues on re-inspection. Documented so future reviews don't re-flag them.

| ID | Original claim | Reality |
|---|---|---|
| FP.1 | `RuntimeEngineManager.swift:423-428` mutate-while-iterate on `mirroredEngines` crashes. | `OrderedDictionary` is a value type with COW; the for-in iterator snapshots the storage, so `removeValue` during iteration is safe and does not crash. (The code was still rewritten as part of B1 for clarity, but the original was not a crash bug.) |
| FP.2 | `RuntimeNetworkConnection.setupReceiver` recursion after `stop()` causes leaks / extra reads. | `NWConnection.cancel()` is idempotent; calling `receive()` on a cancelled connection fires the completion handler with an error and the existing `isStarted` guard in `stop()` prevents re-entry. |
| FP.3 | `RuntimeConnectionBase.underlyingConnection` plain `var` causes crashes under concurrent swap. | The class is explicitly `@unchecked Sendable`, aligned pointer reads/writes are atomic on ARM64/Intel, and the swap happens on `.main`. In practice there are no observed crashes. Downgraded to Minor follow-up (not tracked here — watch for symptoms). |
| FP.4 | `RuntimeLocalSocketClientConnection.pendingHandlers` race from concurrent `setMessageHandler` append. | All `setMessageHandler` calls happen during initial wiring (document open) before any reconnection fires. No steady-state concurrent append/iterate in practice. |
| FP.5 | `RuntimeLocalSocketClientConnection.underlyingConnection` use-after-swap. | Same analysis as FP.3. Writes ordered: `stop()` old, swap new, apply handlers, start. Reads from concurrent `sendMessage` at worst return an error. |
| FP.6 | XPC registry no persistence = total data loss on daemon restart. | The daemon is `KeepAlive=true` now (M4.4 tracks that decision). In practice the daemon doesn't restart during normal operation; the use case the registry is built for is *Host app* restart, not daemon restart. |
