# Bonjour Connection Reliability Improvements

Date: 2026-03-03

## Problem Statement

Bonjour-based discovery and connection between macOS and iOS devices suffered from several reliability issues:

1. **Intermittent device-specific failures** — Some devices could never connect even after granting local network permissions
2. **iOS-first-start not discovered** — If iOS app started before macOS, macOS would consistently fail to connect to the already-advertising iOS device
3. **No recovery from transient failures** — Any connection hiccup was permanent with no retry

## Root Cause Analysis

### Issue 1: NWConnection `.waiting` state immediately killed

`RuntimeNetworkConnection.handleStateChange` treated `.waiting` as a fatal error, calling `stop()` immediately. `.waiting` is a **transient** state indicating the connection is waiting for a viable network path (e.g., during permission negotiation, DNS resolution, or brief network transitions). On some devices/networks, connections pass through `.waiting` briefly before reaching `.ready`.

This was the primary cause of both the intermittent device failures AND the iOS-first-start issue: when macOS discovered the iOS service and attempted to connect, the NWConnection would enter `.waiting` during Bonjour endpoint resolution, get immediately killed, and no retry existed.

**File:** `RuntimeNetworkConnection.swift:152-154`

### Issue 2: NWListener errors silently ignored

`RuntimeNetworkServerConnection.waitForConnection` set a `stateUpdateHandler` on the NWListener that only logged state changes. If the listener entered `.failed`, the continuation was never resumed — the iOS app would hang forever at `try await remoteRuntimeEngine?.connect()` with no error feedback and no retry.

**File:** `RuntimeNetworkConnection.swift:355-357`

### Issue 3: `restartListening` reused cancelled NWListener

After the first client connected, `listener.cancel()` was called. The `restartListening()` method then tried to set `newConnectionHandler` on the cancelled listener without calling `start()` again. A cancelled NWListener cannot be reused — a new instance must be created.

**File:** `RuntimeNetworkConnection.swift:403-404, 411-443`

### Issue 4: `browseResultsChangedHandler` iterated all results instead of changes

Every time NWBrowser reported a change (any service added/removed on the network), the handler iterated **all current results** and called the discovery handler for each. This caused duplicate RuntimeEngine creation for already-connected devices, and since the iOS-side NWListener cancelled after accepting the first connection, subsequent connection attempts to the same device would fail.

**File:** `RuntimeNetwork.swift:95-102`

### Issue 5: No deduplication in RuntimeEngineManager

`appendBonjourRuntimeEngine` blindly appended without checking if an engine for the same endpoint already existed.

**File:** `RuntimeEngineManager.swift:60-63`

### Issue 6: No retry on connection failure

When a Bonjour connection attempt failed, the endpoint was permanently discarded. No retry mechanism existed. Combined with Issue 1, this meant a single transient `.waiting` state permanently prevented connection.

**File:** `RuntimeEngineManager.swift:44-46`

### Issue 7: `RuntimeEngine.connect()` for bonjourClient returns immediately

Unlike `bonjourServer` which awaits the first client connection, `bonjourClient`'s `connect()` returns as soon as the NWConnection is started — **before** it reaches `.ready`. The RuntimeEngine emits `.connected` prematurely. If the NWConnection then enters `.waiting` → `.disconnected`, the engine is briefly added to `bonjourRuntimeEngines` then immediately removed, with no retry.

**File:** `RuntimeCommunicator.swift:57-62`

## Fixes Applied

### Fix 1: `.waiting` tolerance window (10s timeout)

Instead of immediately stopping on `.waiting`, a `DispatchWorkItem` timer gives the connection 10 seconds to transition to `.ready`. If `.ready` is reached, the timer is cancelled. If the timer fires, the connection is stopped.

### Fix 2: NWListener `.failed` handling

The listener's `stateUpdateHandler` now handles `.failed` by resuming the continuation with an error. `waitForConnection` completes once a client connects or the listener fails.

### Fix 3: Recreate NWListener in `restartListening`

Instead of reusing the cancelled listener, `restartListening` stores `serviceName` and `listenerParameters` at init time and creates a fresh NWListener instance each time.

### Fix 4: Process only `.added` changes in browser

`browseResultsChangedHandler` now iterates `changes` (filtering for `.added`) instead of iterating all `results`. A separate `onRemoved` callback handles endpoint removal.

### Fix 5: Endpoint deduplication in RuntimeEngineManager

A `Set<String>` tracks known endpoint names. Duplicate discovery callbacks for the same endpoint name are skipped. Endpoints are removed from the set when their engine disconnects or when the browser reports removal.

### Fix 6: Exponential backoff retry (3 attempts)

Failed Bonjour connections are retried up to 3 times with exponential backoff delays (2s, 4s, 8s). The dedup set is cleared before retry to allow the new attempt.

## Connection Flow (After Fixes)

```
iOS App Starts:
  NWListener created → start(queue:)
  → .ready → Bonjour service advertised
  → waitForConnection (30s timeout)

macOS App Starts:
  NWBrowser created → start(queue:)
  → browseResultsChangedHandler (changes only)
  → .added endpoint → onAdded callback

  RuntimeEngineManager:
  → Check dedup set → not known → insert name
  → Create RuntimeEngine → connect() (immediate)
  → NWConnection starts → .preparing → .waiting?
     → 10s tolerance window (not killed)
     → .ready → connected ✓
  → If fails: retry with 2s/4s/8s backoff (up to 3 attempts)

Reconnection:
  → iOS NWListener.cancel() after first connection
  → Client disconnects → restartListening()
  → New NWListener created → advertises again
  → macOS NWBrowser detects re-added endpoint → connects
```
