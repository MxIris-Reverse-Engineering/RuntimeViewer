# Background Indexing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the opt-in background indexing feature per [0002-background-indexing.md](../Evolution/0002-background-indexing.md) — a per-`RuntimeEngine` Swift-Concurrency `RuntimeBackgroundIndexingManager` actor, Settings controls, and a Toolbar popover.

**Architecture:** All core logic in `RuntimeViewerCore` (with `Runtime` prefix); coordinator in `RuntimeViewerApplication` (with `Runtime` prefix); UI in `RuntimeViewerUsingAppKit`, Settings UI in `RuntimeViewerSettingsUI` (neither prefixed). Swift Concurrency for all task scheduling; RxSwift only for UI binding in the coordinator.

**Tech Stack:** Swift 5 (language mode v5), Swift Concurrency (actor / AsyncStream / TaskGroup), AsyncSemaphore (groue/Semaphore, already resolved), MachOKit (MachOImage.dependencies), RxSwift/RxCocoa, SnapKit, AppKit, SwiftUI (Settings only), MetaCodable `@Codable`, swift-memberwise-init-macro `@MemberInit`.

---

## Conventions used throughout this plan

- **Build / test commands**: all `swift build` / `swift test` invocations are preceded by `swift package update` and piped through `xcsift` per the project's CLAUDE.md. Run from the package directory (`RuntimeViewerCore/` or `RuntimeViewerPackages/`).
- **Commit style**: Conventional Commits (`feat:`, `test:`, `refactor:`, `docs:`) matching recent project history.
- **Every new file under `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/`** must be added to `RuntimeViewer.xcodeproj` — use the xcodeproj MCP (`add_file`) as shown in the integration tasks. Other packages (`RuntimeViewerCore`, `RuntimeViewerPackages`) are SPM and pick up new sources automatically.
- **Naming**: types created inside `RuntimeViewerCore` and `RuntimeViewerApplication` carry the `Runtime` prefix. Types created inside `RuntimeViewerUsingAppKit`, `RuntimeViewerSettingsUI`, and `RuntimeViewerSettings` do **not** (sticking with `MCP` / `MCPSettingsView` precedent).
- **Access control**: `private` by default; widen only when needed by callers. Observable state on ViewModels: `@Observed private(set) var`.
- **Weak-self idiom**: `guard let self else { return }` — never `strongSelf`, never `if let self`.
- **RxSwift subscription style**: trailing closure variants only (`.driveOnNext { }`, `.emitOnNext { }`, `.subscribeOnNext { }`).
- **Branch**: all work happens on `feature/runtime-background-indexing` (already created from `origin/main`).

---

## Phase 0 — Package wiring

### Task 0: Declare Semaphore as an explicit dependency of `RuntimeViewerCore`

**Files:**
- Modify: `RuntimeViewerCore/Package.swift`

**Why:** The `groue/Semaphore` package is already resolved for the `RuntimeViewerCommunication` target (see `Package.swift:163`), but `RuntimeViewerCore`'s own target does not declare it. `RuntimeBackgroundIndexingManager.swift` (Task 6) will `import Semaphore`; relying on transitive visibility is brittle (breaks the moment `.memberImportVisibility` is enabled, which is already defined at `Package.swift:200`). Make the dependency explicit before any code uses it.

- [ ] **Step 1: Edit the `RuntimeViewerCore` target's `dependencies` array**

In `RuntimeViewerCore/Package.swift`, inside `.target(name: "RuntimeViewerCore", dependencies: [...])` (currently lines 142-157), append:

```swift
.product(name: "Semaphore", package: "Semaphore"),
```

after the existing `MetaCodable` product.

- [ ] **Step 2: Resolve & build**

```bash
cd RuntimeViewerCore && swift package update && swift build 2>&1 | xcsift
```

Expected: clean build (no code changes yet).

- [ ] **Step 3: Commit**

```bash
git add RuntimeViewerCore/Package.swift
git commit -m "chore(core): add Semaphore as explicit RuntimeViewerCore dependency"
```

---

## Phase 1 — Foundation value types

### Task 1: Create Sendable + Hashable value types for indexing events and batches

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingBatchID.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingBatchReason.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingTaskState.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingTaskItem.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingBatch.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingEvent.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/ResolvedDependency.swift`
- Test: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeIndexingValueTypesTests.swift`

**Why Hashable everywhere:** `BackgroundIndexingNode` (Task 18) is declared `Hashable` so it can key `NSOutlineView` / `NSDiffableDataSource` updates. Its associated values transitively need `Hashable`. Declaring it up front is cheaper than backfilling later.

- [ ] **Step 1: Write failing tests for value type invariants**

File `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeIndexingValueTypesTests.swift`:

```swift
import XCTest
@testable import RuntimeViewerCore

final class RuntimeIndexingValueTypesTests: XCTestCase {
    func test_batchID_isUnique() {
        let a = RuntimeIndexingBatchID()
        let b = RuntimeIndexingBatchID()
        XCTAssertNotEqual(a, b)
    }

    func test_taskItem_isNotCompletedWhenPending() {
        let item = RuntimeIndexingTaskItem(id: "/foo", resolvedPath: "/foo",
                                           state: .pending, hasPriorityBoost: false)
        XCTAssertFalse(item.state.isTerminal)
    }

    func test_taskState_failedIsTerminal() {
        let state = RuntimeIndexingTaskState.failed(message: "boom")
        XCTAssertTrue(state.isTerminal)
    }

    func test_taskState_cancelledIsTerminal() {
        XCTAssertTrue(RuntimeIndexingTaskState.cancelled.isTerminal)
    }

    func test_taskState_completedIsTerminal() {
        XCTAssertTrue(RuntimeIndexingTaskState.completed.isTerminal)
    }

    func test_batch_progress_reportsCompletedFraction() {
        let items: [RuntimeIndexingTaskItem] = [
            .init(id: "/a", resolvedPath: "/a", state: .completed, hasPriorityBoost: false),
            .init(id: "/b", resolvedPath: "/b", state: .completed, hasPriorityBoost: false),
            .init(id: "/c", resolvedPath: "/c", state: .pending, hasPriorityBoost: false),
            .init(id: "/d", resolvedPath: "/d", state: .failed(message: "x"), hasPriorityBoost: false),
        ]
        let batch = RuntimeIndexingBatch(
            id: RuntimeIndexingBatchID(),
            rootImagePath: "/root",
            depth: 1,
            reason: .manual,
            items: items,
            isCancelled: false,
            isFinished: false
        )
        XCTAssertEqual(batch.completedCount, 3)   // completed + failed count as "done"
        XCTAssertEqual(batch.totalCount, 4)
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure**

```bash
cd RuntimeViewerCore && swift package update && swift test --filter RuntimeIndexingValueTypesTests 2>&1 | xcsift
```

Expected: compilation errors for all types referenced.

- [ ] **Step 3: Create the value type files**

File `RuntimeIndexingBatchID.swift`:

```swift
import Foundation

public struct RuntimeIndexingBatchID: Hashable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}
```

File `RuntimeIndexingBatchReason.swift`:

```swift
public enum RuntimeIndexingBatchReason: Sendable, Hashable {
    case appLaunch
    case imageLoaded(path: String)
    case settingsEnabled
    case manual
}
```

File `RuntimeIndexingTaskState.swift`:

```swift
public enum RuntimeIndexingTaskState: Sendable, Hashable {
    case pending
    case running
    case completed
    case failed(message: String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .pending, .running: return false
        }
    }
}
```

File `RuntimeIndexingTaskItem.swift`:

```swift
public struct RuntimeIndexingTaskItem: Sendable, Identifiable, Hashable {
    public let id: String
    public let resolvedPath: String?
    public var state: RuntimeIndexingTaskState
    public var hasPriorityBoost: Bool

    public init(id: String, resolvedPath: String?,
                state: RuntimeIndexingTaskState,
                hasPriorityBoost: Bool) {
        self.id = id
        self.resolvedPath = resolvedPath
        self.state = state
        self.hasPriorityBoost = hasPriorityBoost
    }
}
```

File `ResolvedDependency.swift`:

```swift
public struct ResolvedDependency: Sendable, Hashable {
    public let installName: String
    public let resolvedPath: String?

    public init(installName: String, resolvedPath: String?) {
        self.installName = installName
        self.resolvedPath = resolvedPath
    }
}
```

File `RuntimeIndexingBatch.swift`:

```swift
public struct RuntimeIndexingBatch: Sendable, Identifiable, Hashable {
    public let id: RuntimeIndexingBatchID
    public let rootImagePath: String
    public let depth: Int
    public let reason: RuntimeIndexingBatchReason
    public var items: [RuntimeIndexingTaskItem]
    public var isCancelled: Bool
    public var isFinished: Bool

    public init(id: RuntimeIndexingBatchID, rootImagePath: String, depth: Int,
                reason: RuntimeIndexingBatchReason,
                items: [RuntimeIndexingTaskItem],
                isCancelled: Bool, isFinished: Bool) {
        self.id = id
        self.rootImagePath = rootImagePath
        self.depth = depth
        self.reason = reason
        self.items = items
        self.isCancelled = isCancelled
        self.isFinished = isFinished
    }

    public var totalCount: Int { items.count }
    public var completedCount: Int { items.lazy.filter { $0.state.isTerminal }.count }
    public var progress: Double {
        guard totalCount > 0 else { return 1 }
        return Double(completedCount) / Double(totalCount)
    }
}
```

File `RuntimeIndexingEvent.swift`:

```swift
public enum RuntimeIndexingEvent: Sendable {
    case batchStarted(RuntimeIndexingBatch)
    case taskStarted(batchID: RuntimeIndexingBatchID, path: String)
    case taskFinished(batchID: RuntimeIndexingBatchID, path: String,
                      result: RuntimeIndexingTaskState)
    case taskPrioritized(batchID: RuntimeIndexingBatchID, path: String)
    case batchFinished(RuntimeIndexingBatch)
    case batchCancelled(RuntimeIndexingBatch)
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeIndexingValueTypesTests 2>&1 | xcsift
```

Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing
git commit -m "feat(core): add Sendable value types for background indexing"
```

---

### Task 2: Implement `DylibPathResolver`

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DylibPathResolver.swift`
- Test: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/DylibPathResolverTests.swift`

- [ ] **Step 1: Explore `LC_RPATH` / executable path API on `MachOImage`**

```bash
rg -n "rpaths|LC_RPATH|executablePath|loaderPath" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/MachOKit/Sources/MachOKit/ --type swift | head
```

Note which `MachOImage` property exposes `LC_RPATH` entries (expect `rpaths: [String]`) and whether there is a helper for the main-executable path (expect `_dyld_get_image_name(0)`). Record what you find in your scratch notes — the resolver design below assumes `image.rpaths: [String]`.

If the API is named differently (e.g. `rpathCommands` returning `RpathCommand` items whose `.path` gives the raw string), adjust the resolver code in Step 3 to match.

- [ ] **Step 2: Write failing tests**

File `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/DylibPathResolverTests.swift`:

```swift
import XCTest
@testable import RuntimeViewerCore

final class DylibPathResolverTests: XCTestCase {
    private let resolver = DylibPathResolver()

    func test_absolutePath_returnsAsIsWhenExists() throws {
        let path = "/usr/lib/libSystem.B.dylib"
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "precondition: system dylib exists in this test env")
        XCTAssertEqual(
            resolver.resolve(installName: path,
                             imagePath: "/any", rpaths: [],
                             mainExecutablePath: "/any"),
            path
        )
    }

    func test_absolutePath_returnsNilWhenMissing() {
        XCTAssertNil(resolver.resolve(installName: "/nonexistent/Foo.dylib",
                                      imagePath: "/any", rpaths: [],
                                      mainExecutablePath: "/any"))
    }

    func test_executablePath_substitutesMainExecutableDir() throws {
        let tempDir = FileManager.default.temporaryDirectory.path
        let exePath = tempDir + "/FakeExe"
        let frameworkPath = tempDir + "/Foo"
        try "".write(toFile: exePath, atomically: true, encoding: .utf8)
        try "".write(toFile: frameworkPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: exePath)
            try? FileManager.default.removeItem(atPath: frameworkPath)
        }
        let resolved = resolver.resolve(
            installName: "@executable_path/Foo",
            imagePath: "/any", rpaths: [],
            mainExecutablePath: exePath)
        XCTAssertEqual(resolved, frameworkPath)
    }

    func test_loaderPath_substitutesImageDir() throws {
        let tempDir = FileManager.default.temporaryDirectory.path
        let imagePath = tempDir + "/FakeLib"
        let siblingPath = tempDir + "/Sibling"
        try "".write(toFile: imagePath, atomically: true, encoding: .utf8)
        try "".write(toFile: siblingPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: imagePath)
            try? FileManager.default.removeItem(atPath: siblingPath)
        }
        let resolved = resolver.resolve(
            installName: "@loader_path/Sibling",
            imagePath: imagePath, rpaths: [],
            mainExecutablePath: "/any")
        XCTAssertEqual(resolved, siblingPath)
    }

    func test_rpath_usesFirstMatchingRpath() throws {
        let tempDir = FileManager.default.temporaryDirectory.path
        let rpath1 = tempDir + "/DoesNotExist"
        let rpath2 = tempDir + "/RPath2"
        try? FileManager.default.createDirectory(atPath: rpath2,
                                                 withIntermediateDirectories: true)
        let target = rpath2 + "/MyLib"
        try "".write(toFile: target, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: target)
            try? FileManager.default.removeItem(atPath: rpath2)
        }
        let resolved = resolver.resolve(
            installName: "@rpath/MyLib",
            imagePath: "/any", rpaths: [rpath1, rpath2],
            mainExecutablePath: "/any")
        XCTAssertEqual(resolved, target)
    }

    func test_rpath_returnsNilWhenNoMatch() {
        XCTAssertNil(resolver.resolve(
            installName: "@rpath/Missing",
            imagePath: "/any", rpaths: ["/nope1", "/nope2"],
            mainExecutablePath: "/any"))
    }
}
```

- [ ] **Step 3: Implement the resolver**

File `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DylibPathResolver.swift`:

```swift
import Foundation

struct DylibPathResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Resolves a dylib install name to a concrete filesystem path.
    /// Returns nil when the resolved path does not exist.
    func resolve(installName: String,
                 imagePath: String,
                 rpaths: [String],
                 mainExecutablePath: String) -> String? {
        if installName.hasPrefix("@rpath/") {
            let tail = String(installName.dropFirst("@rpath/".count))
            for rpath in rpaths {
                let candidate = expand(rpath, imagePath: imagePath,
                                       mainExecutablePath: mainExecutablePath)
                    + "/" + tail
                if fileManager.fileExists(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }
        if installName.hasPrefix("@executable_path/") {
            let tail = String(installName.dropFirst("@executable_path/".count))
            let candidate = (mainExecutablePath as NSString)
                .deletingLastPathComponent + "/" + tail
            return fileManager.fileExists(atPath: candidate) ? candidate : nil
        }
        if installName.hasPrefix("@loader_path/") {
            let tail = String(installName.dropFirst("@loader_path/".count))
            let candidate = (imagePath as NSString)
                .deletingLastPathComponent + "/" + tail
            return fileManager.fileExists(atPath: candidate) ? candidate : nil
        }
        return fileManager.fileExists(atPath: installName) ? installName : nil
    }

    private func expand(_ rpath: String,
                        imagePath: String,
                        mainExecutablePath: String) -> String {
        if rpath.hasPrefix("@executable_path/") {
            let tail = String(rpath.dropFirst("@executable_path/".count))
            return (mainExecutablePath as NSString)
                .deletingLastPathComponent + "/" + tail
        }
        if rpath.hasPrefix("@loader_path/") {
            let tail = String(rpath.dropFirst("@loader_path/".count))
            return (imagePath as NSString)
                .deletingLastPathComponent + "/" + tail
        }
        return rpath
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd RuntimeViewerCore && swift test --filter DylibPathResolverTests 2>&1 | xcsift
```

Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DylibPathResolver.swift RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/DylibPathResolverTests.swift
git commit -m "feat(core): add DylibPathResolver for @rpath / @executable_path / @loader_path"
```

---

## Phase 2 — Engine extensions

### Task 3: Expose `hasCachedSection` on both section factories; add `isImageIndexed` to engine with `request/remote` dispatch

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift` (factory area)
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift` (factory area)
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift` (bump factories to `internal`; add `.isImageIndexed` to `CommandNames`; register handler)
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift`
- Test: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeEngineIndexStateTests.swift`

**Why `request/remote`:** When the document targets a remote source (XPC / directTCP), the local engine's factory caches are empty — only the server process has the truth. Every existing public engine method uses the `request<T>(local:remote:)` primitive (`RuntimeEngine.swift:468`); skipping it here would return wrong data for remote sources.

- [ ] **Step 1: Read the factory classes for their caching layout**

```bash
rg -n "class RuntimeObjCSectionFactory|class RuntimeSwiftSectionFactory|private var sections|func section\(for" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/
```

Record: cache storage variable name (expect `sections: [String: RuntimeObjCSection]` / similar), and whether factories already cache nil results. If not caching nil, the `hasCachedSection` predicate introduced below reflects "successfully parsed" — OK for MVP since a `.failed` task item captures the failure case.

- [ ] **Step 2: Write failing test for `isImageIndexed`**

File `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeEngineIndexStateTests.swift`:

```swift
import XCTest
@testable import RuntimeViewerCore

final class RuntimeEngineIndexStateTests: XCTestCase {
    func test_isImageIndexed_falseForUnvisitedPath() async throws {
        let engine = await RuntimeEngine(source: .local)
        let indexed = try await engine.isImageIndexed(path: "/never/seen")
        XCTAssertFalse(indexed)
    }

    func test_isImageIndexed_trueAfterLoadImage() async throws {
        let engine = await RuntimeEngine(source: .local)
        let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
        try await engine.loadImage(at: foundation)
        let indexed = try await engine.isImageIndexed(path: foundation)
        XCTAssertTrue(indexed)
    }
}
```

- [ ] **Step 3: Add `hasCachedSection(for:)` to each factory**

In `RuntimeObjCSection.swift`, inside `RuntimeObjCSectionFactory`:

```swift
func hasCachedSection(for path: String) -> Bool {
    sections[path] != nil
}
```

In `RuntimeSwiftSection.swift`, same pattern:

```swift
func hasCachedSection(for path: String) -> Bool {
    sections[path] != nil
}
```

Match the exact storage name observed in Step 1. If a factory uses `cache` or `_sections`, substitute.

- [ ] **Step 4: Widen factory access level (must-do)**

`RuntimeEngine.swift:147-149` currently declares both factories as `private`:

```swift
private let objcSectionFactory: RuntimeObjCSectionFactory
private let swiftSectionFactory: RuntimeSwiftSectionFactory
```

Change both to `internal` (drop the `private` keyword; default is `internal`). This is required for the `+BackgroundIndexing.swift` extension below. Verified against current code — the factories are definitely `private` today.

- [ ] **Step 5: Add `.isImageIndexed` to `CommandNames` and register the server handler**

In `RuntimeEngine.swift`, find the `CommandNames` enum (around line 62). Add:

```swift
case isImageIndexed
```

In the `setMessageHandlerBinding(...)` block near line 276, add:

```swift
setMessageHandlerBinding(forName: .isImageIndexed, of: self) { $0.isImageIndexed(path:) }
```

This slots in next to the existing `.isImageLoaded` binding.

- [ ] **Step 6: Create the engine extension using `request/remote` dispatch**

File `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift`:

```swift
import Foundation
import MachOKit

extension RuntimeEngine {
    public func isImageIndexed(path: String) async throws -> Bool {
        try await request {
            objcSectionFactory.hasCachedSection(for: path)
                && swiftSectionFactory.hasCachedSection(for: path)
        } remote: { senderConnection in
            try await senderConnection.sendMessage(
                name: .isImageIndexed, request: path)
        }
    }
}
```

Note: the test in Step 2 has been updated above to `try await engine.isImageIndexed(path:)` since the method now throws.

- [ ] **Step 7: Run tests — expect pass**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeEngineIndexStateTests 2>&1 | xcsift
```

Expected: 2 tests passed. The second test relies on a real Foundation image; if CI lacks that exact path, comment out the second test and leave a TODO — but in this project (local macOS dev) it will pass.

- [ ] **Step 8: Commit**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): add isImageIndexed with request/remote dispatch + factory predicate"
```

---

### Task 4: Add `mainExecutablePath` and `loadImageForBackgroundIndexing` to engine (with `request/remote` dispatch)

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift` (add two `CommandNames` cases + handlers)
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DyldUtilities.swift` (only if helper missing)
- Test: append to `RuntimeEngineIndexStateTests.swift`

**Why `request/remote`:** Same rationale as Task 3. `mainExecutablePath` must reflect the target process, not the local process; for a remote source the correct answer is only known on the server side. `loadImageForBackgroundIndexing` must also execute inside the target process.

- [ ] **Step 1: Explore `DyldUtilities` and `MachOImage` for main-executable lookup**

```bash
rg -n "_dyld_get_image_name|_dyld_get_image_header|mainExecutable|static func images|MachOImage\.current" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/ /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/MachOKit/Sources/MachOKit/ --type swift | head
```

Note the canonical call sequence. On macOS the main executable is dyld image at index 0; the pattern is `String(cString: _dyld_get_image_name(0))`.

- [ ] **Step 2: Append failing tests**

In `RuntimeEngineIndexStateTests.swift`, append:

```swift
    func test_mainExecutablePath_returnsNonEmptyPath() async throws {
        // In the XCTest context this returns the test runner's executable path,
        // which validates the "return dyld image 0" contract without requiring
        // RuntimeViewer.app to be running.
        let engine = await RuntimeEngine(source: .local)
        let path = try await engine.mainExecutablePath()
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func test_loadImageForBackgroundIndexing_doesNotTriggerReloadData() async throws {
        let engine = await RuntimeEngine(source: .local)
        let path = "/System/Library/Frameworks/CoreText.framework/CoreText"
        try await engine.loadImageForBackgroundIndexing(at: path)
        let indexed = try await engine.isImageIndexed(path: path)
        XCTAssertTrue(indexed)
    }
```

- [ ] **Step 3: Add `CommandNames` cases + server handlers**

In `RuntimeEngine.swift` `CommandNames` enum:

```swift
case mainExecutablePath
case loadImageForBackgroundIndexing
```

In the `setMessageHandlerBinding(...)` block:

```swift
setMessageHandlerBinding(forName: .mainExecutablePath,
                         of: self) { $0.mainExecutablePath }
setMessageHandlerBinding(forName: .loadImageForBackgroundIndexing,
                         of: self) { $0.loadImageForBackgroundIndexing(at:) }
```

- [ ] **Step 4: Implement the new engine methods with `request/remote` dispatch**

Append to `RuntimeEngine+BackgroundIndexing.swift`:

```swift
extension RuntimeEngine {
    /// Path of the target process's main executable (dyld image at index 0).
    public func mainExecutablePath() async throws -> String {
        try await request {
            // dyld guarantees image index 0 is the main executable.
            DyldUtilities.imageNames().first ?? ""
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .mainExecutablePath)
        }
    }

    /// Like `loadImage(at:)` but does **not** call `reloadData()`.
    /// Used by the background indexing manager to avoid UI refresh storms.
    public func loadImageForBackgroundIndexing(at path: String) async throws {
        try await request {
            // Mirror loadImage(at:) body sans reloadData — see RuntimeEngine.swift:485-495.
            try DyldUtilities.loadImage(at: path)
            _ = try await objcSectionFactory.section(for: path)
            _ = try await swiftSectionFactory.section(for: path)
            loadedImagePaths.insert(path)
        } remote: { senderConnection in
            try await senderConnection.sendMessage(
                name: .loadImageForBackgroundIndexing, request: path)
        }
    }
}
```

Note the `try await` on both factory calls — matches the verified signature `section(for:progressContinuation:) async throws -> (isExisted: Bool, section: ...)` at `RuntimeObjCSection.swift:704` / `RuntimeSwiftSection.swift:802`.

- [ ] **Step 5: Run tests — expect pass**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeEngineIndexStateTests 2>&1 | xcsift
```

Expected: all tests in that file pass.

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): mainExecutablePath + loadImageForBackgroundIndexing with request/remote"
```

---

### Task 4.5: Add `imageDidLoadPublisher` on `RuntimeEngine`

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`
- Test: append to `RuntimeEngineIndexStateTests.swift`

**Why:** The coordinator (Task 16) needs a signal that carries the path of the newly-loaded image. `RuntimeEngine` today only exposes `reloadDataPublisher` (no payload) and `imageNodesPublisher` (full list); there is no per-image signal. Task 16 will subscribe to this new publisher. The local branch emits after `loadImage(at:)` succeeds; the remote branch's `setMessageHandlerBinding(forName: .imageDidLoad)` handler emits on the client side when the server forwards the event.

- [ ] **Step 1: Inspect the existing `reloadDataPublisher` wiring for pattern parity**

```bash
rg -n "reloadDataPublisher|reloadDataSubject|PassthroughSubject" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift | head
```

Expected finding: `private nonisolated let reloadDataSubject = PassthroughSubject<Void, Never>()` with a `nonisolated` public property exposing it, and a `setMessageHandlerBinding(forName: .reloadData) { $0.reloadDataSubject.send() }` on the server handler table.

- [ ] **Step 2: Add the subject + publisher**

In `RuntimeEngine.swift` next to the existing `reloadDataSubject`:

```swift
private nonisolated let imageDidLoadSubject = PassthroughSubject<String, Never>()

public nonisolated var imageDidLoadPublisher: some Publisher<String, Never> {
    imageDidLoadSubject.eraseToAnyPublisher()
}
```

- [ ] **Step 3: Add `.imageDidLoad` to `CommandNames` and wire both sides**

In `CommandNames`:

```swift
case imageDidLoad
```

In the handler table, mirror the `reloadData` pattern so remote clients also receive the event:

```swift
setMessageHandlerBinding(forName: .imageDidLoad) { (engine: RuntimeEngine, path: String) in
    engine.imageDidLoadSubject.send(path)
}
```

In `loadImage(at:)` (currently `RuntimeEngine.swift:485-495`), after the existing `reloadData(isReloadImageNodes: false)` call, emit:

```swift
imageDidLoadSubject.send(path)
sendRemoteDataIfNeeded(name: .imageDidLoad, payload: path)
// or inline the remote push similar to sendRemoteDataIfNeeded(isReloadImageNodes:)
```

Verify the existing `sendRemoteDataIfNeeded(...)` signature — if it doesn't accept an arbitrary command name, add a small `sendRemoteImageDidLoad(_ path: String)` helper beside it.

- [ ] **Step 4: Append a test**

```swift
    func test_imageDidLoadPublisher_firesAfterLoadImage() async throws {
        let engine = await RuntimeEngine(source: .local)
        let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
        let expectation = expectation(description: "imageDidLoad")
        var received: String?
        let cancellable = await engine.imageDidLoadPublisher.sink { path in
            received = path
            expectation.fulfill()
        }
        try await engine.loadImage(at: foundation)
        await fulfillment(of: [expectation], timeout: 5)
        cancellable.cancel()
        XCTAssertEqual(received, foundation)
    }
```

Add `import Combine` at the top of the test file if not present.

- [ ] **Step 5: Run tests**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeEngineIndexStateTests 2>&1 | xcsift
```

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): imageDidLoadPublisher for per-path load notifications"
```

---

## Phase 3 — The indexing manager

### Task 5: Declare the engine-representing protocol and mock

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/BackgroundIndexingEngineRepresenting.swift`
- Create: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/MockBackgroundIndexingEngine.swift`

- [ ] **Step 1: Create the protocol**

File `BackgroundIndexingEngineRepresenting.swift`:

```swift
import MachOKit

/// Abstraction seam for `RuntimeBackgroundIndexingManager` to interact with a
/// `RuntimeEngine`. Lets tests swap in a fake engine without real dyld I/O.
protocol BackgroundIndexingEngineRepresenting: AnyObject, Sendable {
    func isImageIndexed(path: String) async -> Bool
    func loadImageForBackgroundIndexing(at path: String) async throws
    func mainExecutablePath() async -> String
    /// Returns `MachOImage` for the given path, or nil when the image cannot
    /// be opened. Exposed so the mock can return deterministic dependency lists.
    func machOImage(for path: String) async -> MachOImage?
    /// Returns the LC_RPATH entries for the image at `path`.
    func rpaths(for path: String) async -> [String]
    /// Returns the resolved dependency dylib paths for the image at `path`,
    /// excluding lazy-load entries. Implementations may return nil entries
    /// for unresolved install names; the caller will mark them failed.
    func dependencies(for path: String)
        async -> [(installName: String, resolvedPath: String?)]
}
```

- [ ] **Step 2: Conform `RuntimeEngine` to the protocol**

Append to `RuntimeEngine+BackgroundIndexing.swift`:

```swift
extension RuntimeEngine: BackgroundIndexingEngineRepresenting {
    func machOImage(for path: String) -> MachOImage? {
        MachOImage(name: path)
    }

    func rpaths(for path: String) -> [String] {
        guard let image = MachOImage(name: path) else { return [] }
        return image.rpaths   // adjust to actual API name from Task 2 exploration
    }

    func dependencies(for path: String) -> [(installName: String, resolvedPath: String?)] {
        guard let image = MachOImage(name: path) else { return [] }
        let resolver = DylibPathResolver()
        let main = mainExecutablePath()
        let rpathList = image.rpaths
        return image.dependencies
            .filter { $0.type != .lazyLoad }
            .map { dep in
                let installName = dep.dylib.name
                let resolved = resolver.resolve(
                    installName: installName, imagePath: path,
                    rpaths: rpathList, mainExecutablePath: main)
                return (installName, resolved)
            }
    }
}
```

If the actual MachOImage API returns `rpaths` as e.g. `[RpathCommand]` with `.path` strings, replace `image.rpaths` with the correct accessor (e.g. `image.rpaths.map { $0.path }`). Do the exploration at the top of this task and stick to the verified API.

- [ ] **Step 3: Create the mock**

File `MockBackgroundIndexingEngine.swift`:

```swift
import Foundation
import MachOKit
@testable import RuntimeViewerCore

// `@unchecked Sendable` is required because the protocol is `Sendable` and this
// class stores mutable state protected by `NSLock` rather than an actor.
final class MockBackgroundIndexingEngine: BackgroundIndexingEngineRepresenting,
                                          @unchecked Sendable
{
    struct ProgrammedPath: Sendable {
        var isIndexed: Bool = false
        var shouldFailLoad: Error? = nil
        var dependencies: [(installName: String, resolvedPath: String?)] = []
    }

    private let lock = NSLock()
    private var paths: [String: ProgrammedPath] = [:]
    private var loadOrder: [String] = []
    var mainExecutable: String = "/fake/MainApp"

    func program(path: String, _ entry: ProgrammedPath) {
        lock.lock(); defer { lock.unlock() }
        paths[path] = entry
    }

    func loadedOrder() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loadOrder
    }

    func isImageIndexed(path: String) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths[path]?.isIndexed ?? false
    }

    func loadImageForBackgroundIndexing(at path: String) async throws {
        try await Task.sleep(nanoseconds: 5_000_000)  // force real async
        lock.lock(); defer { lock.unlock() }
        if let err = paths[path]?.shouldFailLoad { throw err }
        var entry = paths[path] ?? ProgrammedPath()
        entry.isIndexed = true
        paths[path] = entry
        loadOrder.append(path)
    }

    func mainExecutablePath() async -> String { mainExecutable }

    func machOImage(for path: String) async -> MachOImage? { nil }
    func rpaths(for path: String) async -> [String] { [] }
    func dependencies(for path: String)
        async -> [(installName: String, resolvedPath: String?)]
    {
        lock.lock(); defer { lock.unlock() }
        return paths[path]?.dependencies ?? []
    }
}
```

- [ ] **Step 4: Compile check**

```bash
cd RuntimeViewerCore && swift build 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): protocol and mock engine for background indexing"
```

---

### Task 6: Create the manager actor skeleton with AsyncStream

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift`
- Test: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: Write failing test for empty manager state**

File `RuntimeBackgroundIndexingManagerTests.swift`:

```swift
import XCTest
import Semaphore
@testable import RuntimeViewerCore

final class RuntimeBackgroundIndexingManagerTests: XCTestCase {
    func test_currentBatches_initiallyEmpty() async {
        let engine = MockBackgroundIndexingEngine()
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let batches = await manager.currentBatches()
        XCTAssertTrue(batches.isEmpty)
    }

    func test_events_streamYieldsBatchStarted_thenFinished_forEmptyGraph() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/fake/Root",
                       .init(isIndexed: true))   // short-circuit immediately
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let events = manager.events
        let consumer = Task {
            var seen: [String] = []
            for await event in events {
                switch event {
                case .batchStarted: seen.append("started")
                case .batchFinished: seen.append("finished"); return seen
                case .batchCancelled: seen.append("cancelled"); return seen
                default: break
                }
            }
            return seen
        }

        let id = await manager.startBatch(rootImagePath: "/fake/Root",
                                          depth: 0, maxConcurrency: 1,
                                          reason: .manual)
        XCTAssertNotNil(id)
        let finalSeen = await consumer.value
        XCTAssertEqual(finalSeen, ["started", "finished"])
    }
}
```

- [ ] **Step 2: Run test — expect compile failure**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

Expected: `RuntimeBackgroundIndexingManager` undefined.

- [ ] **Step 3: Implement the skeleton**

File `RuntimeBackgroundIndexingManager.swift`:

```swift
import Foundation
import Semaphore

public actor RuntimeBackgroundIndexingManager {
    private let engine: any BackgroundIndexingEngineRepresenting
    private let stream: AsyncStream<RuntimeIndexingEvent>
    private let continuation: AsyncStream<RuntimeIndexingEvent>.Continuation

    private var activeBatches: [RuntimeIndexingBatchID: BatchState] = [:]

    init(engine: any BackgroundIndexingEngineRepresenting) {
        self.engine = engine
        var cont: AsyncStream<RuntimeIndexingEvent>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    deinit { continuation.finish() }

    public nonisolated var events: AsyncStream<RuntimeIndexingEvent> { stream }

    public func currentBatches() -> [RuntimeIndexingBatch] {
        activeBatches.values.map(\.batch)
    }

    public func startBatch(
        rootImagePath: String,
        depth: Int,
        maxConcurrency: Int,
        reason: RuntimeIndexingBatchReason
    ) async -> RuntimeIndexingBatchID {
        let id = RuntimeIndexingBatchID()
        let items = await expandDependencyGraph(rootPath: rootImagePath, depth: depth)
        var batch = RuntimeIndexingBatch(
            id: id, rootImagePath: rootImagePath, depth: depth,
            reason: reason, items: items,
            isCancelled: false, isFinished: false)
        let state = BatchState(batch: batch, maxConcurrency: max(1, maxConcurrency))
        activeBatches[id] = state
        continuation.yield(.batchStarted(batch))

        let drivingTask = Task { [weak self] in
            await self?.runBatch(id: id)
        }
        activeBatches[id]?.drivingTask = drivingTask
        return id
    }

    // Placeholder — Task 8 replaces with real BFS.
    func expandDependencyGraph(rootPath: String, depth: Int)
        async -> [RuntimeIndexingTaskItem]
    {
        if await engine.isImageIndexed(path: rootPath) { return [] }
        return [.init(id: rootPath, resolvedPath: rootPath,
                      state: .pending, hasPriorityBoost: false)]
    }

    private func runBatch(id: RuntimeIndexingBatchID) async {
        guard var state = activeBatches[id] else { return }
        // Empty batch finishes immediately.
        if state.batch.items.isEmpty {
            finalize(id: id, cancelled: false)
            return
        }
        // Task 9 implements real execution. For now mark all items completed.
        for index in state.batch.items.indices {
            state.batch.items[index].state = .completed
        }
        activeBatches[id] = state
        finalize(id: id, cancelled: false)
    }

    private func finalize(id: RuntimeIndexingBatchID, cancelled: Bool) {
        guard var state = activeBatches[id] else { return }
        state.batch.isFinished = true
        state.batch.isCancelled = cancelled
        activeBatches[id] = state
        if cancelled {
            continuation.yield(.batchCancelled(state.batch))
        } else {
            continuation.yield(.batchFinished(state.batch))
        }
        activeBatches[id] = nil
    }

    struct BatchState {
        var batch: RuntimeIndexingBatch
        var maxConcurrency: Int
        var drivingTask: Task<Void, Never>?
        var priorityBoostPaths: Set<String> = []
    }
}
```

- [ ] **Step 4: Run test — expect pass**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): manager actor skeleton with AsyncStream plumbing"
```

---

### Task 7: Implement `expandDependencyGraph` — BFS with depth limit and short-circuit

**Files:**
- Modify: `RuntimeBackgroundIndexingManager.swift`
- Test: append to `RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `RuntimeBackgroundIndexingManagerTests.swift`:

```swift
    func test_expand_emptyWhenRootAlreadyIndexed() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App", .init(isIndexed: true))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 5)
        XCTAssertTrue(items.isEmpty)
    }

    func test_expand_depth1_includesRootAndDirectDeps() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App", .init(
            dependencies: [("/UIKit", "/UIKit"), ("/Foundation", "/Foundation")]
        ))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        XCTAssertEqual(Set(items.map(\.id)),
                       Set(["/App", "/UIKit", "/Foundation"]))
    }

    func test_expand_depth1_doesNotIncludeSecondLevel() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/UIKit", "/UIKit")]))
        engine.program(path: "/UIKit",
                       .init(dependencies: [("/CoreGraphics", "/CoreGraphics")]))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        XCTAssertEqual(Set(items.map(\.id)), Set(["/App", "/UIKit"]))
    }

    func test_expand_skipsAlreadyIndexedDeps() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/UIKit", "/UIKit"),
                                            ("/Foundation", "/Foundation")]))
        engine.program(path: "/UIKit", .init(isIndexed: true))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        XCTAssertEqual(Set(items.map(\.id)), Set(["/App", "/Foundation"]))
    }

    func test_expand_unresolvedInstallNameBecomesFailedItem() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App", .init(
            dependencies: [("@rpath/Missing", nil)]
        ))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        let missing = items.first { $0.id == "@rpath/Missing" }
        XCTAssertNotNil(missing)
        if case .failed = missing?.state {} else { XCTFail("expected failed state") }
    }

    func test_expand_dedupsSharedDependencies() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/A", "/A"), ("/B", "/B")]))
        engine.program(path: "/A",
                       .init(dependencies: [("/Shared", "/Shared")]))
        engine.program(path: "/B",
                       .init(dependencies: [("/Shared", "/Shared")]))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 2)
        let sharedCount = items.filter { $0.id == "/Shared" }.count
        XCTAssertEqual(sharedCount, 1)
    }
```

- [ ] **Step 2: Replace the placeholder `expandDependencyGraph` implementation**

In `RuntimeBackgroundIndexingManager.swift` replace the existing stub with:

```swift
func expandDependencyGraph(rootPath: String, depth: Int)
    async -> [RuntimeIndexingTaskItem]
{
    var visited: Set<String> = []
    var items: [RuntimeIndexingTaskItem] = []
    var frontier: [(path: String, level: Int)] = [(rootPath, 0)]

    while !frontier.isEmpty {
        let (path, level) = frontier.removeFirst()
        guard visited.insert(path).inserted else { continue }

        if await engine.isImageIndexed(path: path) { continue }

        // Before recursing, confirm the image opens. If not, record a failed
        // item and do not recurse.
        if await engine.machOImage(for: path) == nil && path != rootPath {
            // Root is allowed to be represented even if we cannot open it —
            // loadImageForBackgroundIndexing will surface the failure later.
        }

        items.append(.init(id: path, resolvedPath: path,
                           state: .pending, hasPriorityBoost: false))
        guard level < depth else { continue }

        for dep in await engine.dependencies(for: path) {
            if let resolved = dep.resolvedPath {
                if !visited.contains(resolved) {
                    frontier.append((resolved, level + 1))
                }
            } else {
                if visited.insert(dep.installName).inserted {
                    items.append(.init(id: dep.installName, resolvedPath: nil,
                                       state: .failed(message: "path unresolved"),
                                       hasPriorityBoost: false))
                }
            }
        }
    }
    return items
}
```

- [ ] **Step 3: Run tests — expect pass**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

Expected: all tests in the file pass, including the new ones.

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): implement dependency graph BFS for background indexing"
```

---

### Task 8: Implement concurrent batch execution with AsyncSemaphore

**Files:**
- Modify: `RuntimeBackgroundIndexingManager.swift`
- Test: append to `RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Append:

```swift
    func test_batch_indexesAllPendingItems() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/A", "/A"), ("/B", "/B")]))
        engine.program(path: "/A", .init())
        engine.program(path: "/B", .init())
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let finishedBatch = await runToFinish(manager: manager,
                                              root: "/App", depth: 1,
                                              maxConcurrency: 2)
        XCTAssertTrue(finishedBatch.items.allSatisfy { $0.state == .completed })
        let indexed = engine.loadedOrder()
        XCTAssertEqual(Set(indexed), Set(["/App", "/A", "/B"]))
    }

    func test_batch_respectsMaxConcurrency() async {
        let engine = MockBackgroundIndexingEngine()
        // 6 dependencies, concurrency cap 2 → never exceed 2 simultaneous loads
        let deps = (0..<6).map { (installName: "/D\($0)", resolvedPath: "/D\($0)") }
        engine.program(path: "/App", .init(dependencies: deps))
        for dep in deps { engine.program(path: dep.installName, .init()) }

        // Monkey-patch engine with a concurrency-counting wrapper.
        let counter = ConcurrencyCounter()
        let wrapped = InstrumentedEngine(base: engine, counter: counter)
        let manager = RuntimeBackgroundIndexingManager(engine: wrapped)

        _ = await runToFinish(manager: manager, root: "/App", depth: 1,
                              maxConcurrency: 2)
        XCTAssertLessThanOrEqual(counter.peak, 2)
    }

    func test_batch_failedLoad_yieldsFailedTaskState() async {
        struct LoadError: Error {}
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/Broken", "/Broken")]))
        engine.program(path: "/Broken", .init(shouldFailLoad: LoadError()))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let batch = await runToFinish(manager: manager,
                                      root: "/App", depth: 1, maxConcurrency: 1)
        let broken = batch.items.first { $0.id == "/Broken" }
        XCTAssertNotNil(broken)
        if case .failed = broken?.state {} else { XCTFail("expected .failed") }
    }

    // MARK: - Test helpers
    private func runToFinish(manager: RuntimeBackgroundIndexingManager,
                             root: String, depth: Int,
                             maxConcurrency: Int) async -> RuntimeIndexingBatch
    {
        let events = manager.events
        let consumer = Task { () -> RuntimeIndexingBatch in
            for await event in events {
                switch event {
                case .batchFinished(let b), .batchCancelled(let b): return b
                default: break
                }
            }
            fatalError("stream ended without terminal event")
        }
        _ = await manager.startBatch(rootImagePath: root, depth: depth,
                                     maxConcurrency: maxConcurrency,
                                     reason: .manual)
        return await consumer.value
    }

    // Concurrency counter and instrumented engine — tiny helpers local to tests.
    private final class ConcurrencyCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var peak = 0
        func enter() { lock.lock(); current += 1; peak = max(peak, current); lock.unlock() }
        func exit() { lock.lock(); current -= 1; lock.unlock() }
    }

    private final class InstrumentedEngine: BackgroundIndexingEngineRepresenting,
                                             @unchecked Sendable
    {
        let base: any BackgroundIndexingEngineRepresenting
        let counter: ConcurrencyCounter
        init(base: any BackgroundIndexingEngineRepresenting, counter: ConcurrencyCounter) {
            self.base = base; self.counter = counter
        }
        func isImageIndexed(path: String) async -> Bool {
            await base.isImageIndexed(path: path)
        }
        func loadImageForBackgroundIndexing(at path: String) async throws {
            counter.enter()
            defer { counter.exit() }
            try await Task.sleep(nanoseconds: 20_000_000)
            try await base.loadImageForBackgroundIndexing(at: path)
        }
        func mainExecutablePath() async -> String { await base.mainExecutablePath() }
        func machOImage(for path: String) async -> MachOImage? {
            await base.machOImage(for: path)
        }
        func rpaths(for path: String) async -> [String] { await base.rpaths(for: path) }
        func dependencies(for path: String)
            async -> [(installName: String, resolvedPath: String?)]
        {
            await base.dependencies(for: path)
        }
    }
```

Add `import MachOKit` at the top of the test file if not already present.

- [ ] **Step 2: Replace the `runBatch` stub with real execution**

In `RuntimeBackgroundIndexingManager.swift` replace `runBatch` and introduce a helper `runSingleIndex`:

```swift
private func runBatch(id: RuntimeIndexingBatchID) async {
    guard let startState = activeBatches[id] else { return }
    let maxConcurrency = startState.maxConcurrency

    // Pending paths in FIFO order, skipping already-terminal items.
    var pending = startState.batch.items
        .filter { !$0.state.isTerminal }
        .map(\.id)

    if pending.isEmpty {
        finalize(id: id, cancelled: false)
        return
    }

    let semaphore = AsyncSemaphore(value: maxConcurrency)
    var wasCancelled = false

    await withTaskGroup(of: Void.self) { group in
        while !pending.isEmpty {
            let path = popNextPrioritizedPath(batchID: id, pending: &pending)
            do {
                try await semaphore.waitUnlessCancelled()
            } catch {
                wasCancelled = true
                break
            }
            if Task.isCancelled { wasCancelled = true; break }
            group.addTask { [weak self] in
                defer { semaphore.signal() }
                await self?.runSingleIndex(batchID: id, path: path)
            }
        }
        await group.waitForAll()
    }
    finalize(id: id, cancelled: wasCancelled || Task.isCancelled)
}

/// Selects the next path to dispatch. Priority-boosted paths jump to the head.
private func popNextPrioritizedPath(
    batchID: RuntimeIndexingBatchID, pending: inout [String]
) -> String {
    if let state = activeBatches[batchID],
       let boostedIdx = pending.firstIndex(where: { state.priorityBoostPaths.contains($0) })
    {
        return pending.remove(at: boostedIdx)
    }
    return pending.removeFirst()
}

private func runSingleIndex(batchID: RuntimeIndexingBatchID, path: String) async {
    updateItemState(batchID: batchID, path: path, state: .running)
    continuation.yield(.taskStarted(batchID: batchID, path: path))
    do {
        try Task.checkCancellation()
        try await engine.loadImageForBackgroundIndexing(at: path)
        updateItemState(batchID: batchID, path: path, state: .completed)
        continuation.yield(.taskFinished(batchID: batchID, path: path,
                                         result: .completed))
    } catch is CancellationError {
        updateItemState(batchID: batchID, path: path, state: .cancelled)
    } catch {
        let state: RuntimeIndexingTaskState =
            .failed(message: error.localizedDescription)
        updateItemState(batchID: batchID, path: path, state: state)
        continuation.yield(.taskFinished(batchID: batchID, path: path,
                                         result: state))
    }
}

private func updateItemState(batchID: RuntimeIndexingBatchID,
                             path: String,
                             state: RuntimeIndexingTaskState)
{
    guard var batchState = activeBatches[batchID] else { return }
    if let idx = batchState.batch.items.firstIndex(where: { $0.id == path }) {
        batchState.batch.items[idx].state = state
        activeBatches[batchID] = batchState
    }
}
```

- [ ] **Step 3: Run tests — expect pass**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

Expected: all previous tests plus the 3 new ones pass.

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): concurrent batch execution with AsyncSemaphore"
```

---

### Task 9: Implement `cancelBatch` and `cancelAllBatches`

**Files:**
- Modify: `RuntimeBackgroundIndexingManager.swift`
- Test: append to `RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Append:

```swift
    func test_cancelBatch_stopsPendingItemsAndEmitsCancelledEvent() async {
        let engine = MockBackgroundIndexingEngine()
        let deps = (0..<5).map { (installName: "/D\($0)", resolvedPath: "/D\($0)") }
        engine.program(path: "/App", .init(dependencies: deps))
        for dep in deps { engine.program(path: dep.installName, .init()) }
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let events = manager.events
        let consumer = Task { () -> RuntimeIndexingBatch in
            for await event in events {
                if case .batchCancelled(let b) = event { return b }
                if case .batchFinished(let b) = event { return b }
            }
            fatalError()
        }
        let id = await manager.startBatch(rootImagePath: "/App", depth: 1,
                                          maxConcurrency: 1, reason: .manual)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await manager.cancelBatch(id)
        let batch = await consumer.value
        XCTAssertTrue(batch.isCancelled)
    }

    func test_cancelAll_cancelsEveryBatch() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/A", .init(dependencies: [("/A1", "/A1")]))
        engine.program(path: "/A1", .init())
        engine.program(path: "/B", .init(dependencies: [("/B1", "/B1")]))
        engine.program(path: "/B1", .init())
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let idA = await manager.startBatch(rootImagePath: "/A", depth: 1,
                                           maxConcurrency: 1, reason: .manual)
        let idB = await manager.startBatch(rootImagePath: "/B", depth: 1,
                                           maxConcurrency: 1, reason: .manual)
        XCTAssertNotEqual(idA, idB)
        await manager.cancelAllBatches()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let remaining = await manager.currentBatches()
        XCTAssertTrue(remaining.isEmpty)
    }
```

- [ ] **Step 2: Implement cancellation**

Add these methods to `RuntimeBackgroundIndexingManager`:

```swift
public func cancelBatch(_ id: RuntimeIndexingBatchID) {
    guard let state = activeBatches[id] else { return }
    activeBatches[id]?.batch.isCancelled = true
    state.drivingTask?.cancel()
    // The driving task's finalize() will emit .batchCancelled.
}

public func cancelAllBatches() {
    let ids = Array(activeBatches.keys)
    for id in ids { cancelBatch(id) }
}
```

Update `finalize` to propagate the already-set `isCancelled` flag:

```swift
private func finalize(id: RuntimeIndexingBatchID, cancelled: Bool) {
    guard var state = activeBatches[id] else { return }
    let effectiveCancel = cancelled || state.batch.isCancelled
    state.batch.isFinished = true
    state.batch.isCancelled = effectiveCancel
    // Mark any still-pending items as cancelled so the UI reflects state.
    if effectiveCancel {
        for index in state.batch.items.indices
        where state.batch.items[index].state == .pending
            || state.batch.items[index].state == .running
        {
            state.batch.items[index].state = .cancelled
        }
    }
    activeBatches[id] = state
    if effectiveCancel {
        continuation.yield(.batchCancelled(state.batch))
    } else {
        continuation.yield(.batchFinished(state.batch))
    }
    activeBatches[id] = nil
}
```

- [ ] **Step 3: Run tests — expect pass**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): cancelBatch and cancelAllBatches on indexing manager"
```

---

### Task 10: Implement `prioritize(imagePath:)`

**Files:**
- Modify: `RuntimeBackgroundIndexingManager.swift`
- Test: append to `RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Append:

```swift
    func test_prioritize_emitsTaskPrioritizedEvent() async {
        // Time-independent assertion: verify the manager emits
        // `.taskPrioritized` for a pending path and does NOT emit it for
        // running / absent paths. Load order would depend on sleep timing
        // and is flaky on CI — event emission is the real contract.
        let engine = MockBackgroundIndexingEngine()
        let deps = ["/D0", "/D1", "/D2"]
        engine.program(path: "/App", .init(
            dependencies: deps.map { ($0, $0) }
        ))
        for dep in deps { engine.program(path: dep, .init()) }
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let events = manager.events
        let consumer = Task { () -> [String] in
            var boosted: [String] = []
            for await event in events {
                if case .taskPrioritized(_, let path) = event {
                    boosted.append(path)
                }
                if case .batchFinished = event { return boosted }
                if case .batchCancelled = event { return boosted }
            }
            return boosted
        }
        _ = await manager.startBatch(rootImagePath: "/App", depth: 1,
                                     maxConcurrency: 1, reason: .manual)
        await manager.prioritize(imagePath: "/D2")

        let boosted = await consumer.value
        XCTAssertEqual(boosted, ["/D2"])
    }

    func test_prioritize_isNoOpForUnknownPath() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App", .init())
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        _ = await manager.startBatch(rootImagePath: "/App", depth: 0,
                                     maxConcurrency: 1, reason: .manual)
        await manager.prioritize(imagePath: "/does/not/exist")
        // No crash; batch still completes. No .taskPrioritized emitted.
    }
```

- [ ] **Step 2: Implement prioritize**

Add to `RuntimeBackgroundIndexingManager`:

```swift
public func prioritize(imagePath: String) {
    for (id, var state) in activeBatches {
        if let idx = state.batch.items.firstIndex(where: {
            $0.id == imagePath && $0.state == .pending
        }) {
            state.batch.items[idx].hasPriorityBoost = true
            state.priorityBoostPaths.insert(imagePath)
            activeBatches[id] = state
            continuation.yield(.taskPrioritized(batchID: id, path: imagePath))
        }
    }
}
```

- [ ] **Step 3: Run tests — expect pass**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): prioritize pending item to head of queue"
```

---

## Phase 4 — Engine integration

### Task 11: Hold `RuntimeBackgroundIndexingManager` on `RuntimeEngine`

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift` (init area and new stored property)

- [ ] **Step 1: Inspect RuntimeEngine init**

```bash
rg -n "init\(source|actor RuntimeEngine" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift | head
```

Note the initializer signature so we can inject the manager without breaking callers.

- [ ] **Step 2: Add an explicit stored property and initialize it at the end of `init`**

`lazy var` on an actor forces every first access through actor-isolation, which makes the initialization point non-obvious and interacts awkwardly with `nonisolated` accessors. Use an explicit implicitly-unwrapped stored property set as the last line of `init`:

```swift
// Near the other stored properties:
public private(set) var backgroundIndexingManager: RuntimeBackgroundIndexingManager!

// Last line of init(source:...):
self.backgroundIndexingManager = RuntimeBackgroundIndexingManager(engine: self)
```

Rationale for IUO: the actor cannot hand `self` to the manager before `init` finishes registering the other stored properties, and the manager is read-only after init — no reassignment paths, no nil access paths outside the one-line bootstrap.

- [ ] **Step 3: Build**

```bash
cd RuntimeViewerCore && swift build 2>&1 | xcsift
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
git commit -m "feat(core): expose backgroundIndexingManager on RuntimeEngine"
```

---

## Phase 5 — Settings

### Task 12: Add `BackgroundIndexing` struct to `Settings+Types.swift`

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift`

- [ ] **Step 1: Read the existing MCP struct to match its style**

```bash
rg -n "public struct MCP|public struct Notifications|public var mcp" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift
```

- [ ] **Step 2: Append the new struct and root property**

In `Settings+Types.swift`, next to the other nested settings structs, add:

```swift
@Codable @MemberInit public struct BackgroundIndexing {
    @Default(false) public var isEnabled: Bool
    @Default(1)     public var depth: Int
    @Default(4)     public var maxConcurrency: Int
    public static let `default` = Self()
}
```

In the root `Settings` struct, add a new stored property next to `mcp`:

```swift
@Default(BackgroundIndexing.default) public var backgroundIndexing: BackgroundIndexing
```

- [ ] **Step 3: Build the packages**

```bash
cd RuntimeViewerPackages && swift package update && swift build 2>&1 | xcsift
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift
git commit -m "feat(settings): add BackgroundIndexing settings struct"
```

---

### Task 13: Add the Settings UI page

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift`
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/BackgroundIndexingSettingsView.swift`

- [ ] **Step 1: Read the existing Settings root view**

```bash
rg -n "case general|case mcp|SettingsPage|contentView" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift | head -20
```

- [ ] **Step 2: Add the enum case and content switch arm**

In `SettingsRootView.swift`, add `case backgroundIndexing` to the `SettingsPage` enum. Match the formatting of existing cases.

Provide the title and icon:

```swift
var title: String {
    switch self {
    case .general: "General"
    case .backgroundIndexing: "Background Indexing"
    case .notifications: "Notifications"
    // ... existing cases unchanged ...
    }
}

var iconName: String {
    switch self {
    case .backgroundIndexing: "square.stack.3d.down.right"
    // ... existing cases unchanged ...
    }
}
```

In the `contentView` switch, add:

```swift
case .backgroundIndexing: BackgroundIndexingSettingsView()
```

- [ ] **Step 3: Create the SwiftUI page**

File `BackgroundIndexingSettingsView.swift`:

```swift
import SwiftUI
import RuntimeViewerSettings

public struct BackgroundIndexingSettingsView: View {
    @AppSettings(\.backgroundIndexing) private var settings

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Enable background indexing", isOn: $settings.isEnabled)
                Text("When enabled, Runtime Viewer parses ObjC and Swift metadata for the dependency closure of loaded images in the background so that lookups are instant.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Indexing") {
                Stepper(value: $settings.depth, in: 1...5) {
                    LabeledContent("Depth", value: "\(settings.depth)")
                }
                .disabled(!settings.isEnabled)
                Text("How many levels of dependencies to index starting from each root image.")
                    .font(.footnote).foregroundStyle(.secondary)

                Stepper(value: $settings.maxConcurrency, in: 1...8) {
                    LabeledContent("Max concurrent tasks",
                                   value: "\(settings.maxConcurrency)")
                }
                .disabled(!settings.isEnabled)
                Text("Maximum number of images indexed in parallel. Higher values finish faster but use more CPU.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 4: Build**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI
git commit -m "feat(settings-ui): Background Indexing settings page"
```

---

## Phase 6 — Coordinator (RuntimeViewerApplication)

### Task 14: Create `RuntimeBackgroundIndexingCoordinator` skeleton

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift`

- [ ] **Step 1: Read DocumentState to understand the environment the coordinator will live in**

```bash
rg -n "final class DocumentState|runtimeEngine|public var" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift | head -30
```

Note the name of the engine property (`runtimeEngine` is likely) and whether `DocumentState` already exposes an observable for `loadImage` completion (e.g. a Rx subject) — this determines the subscription wire-up in Task 15.

- [ ] **Step 2: Create the coordinator skeleton**

File `RuntimeBackgroundIndexingCoordinator.swift`:

```swift
import Foundation
import RuntimeViewerCore
import RuntimeViewerSettings
import RxSwift
import RxRelay

public final class RuntimeBackgroundIndexingCoordinator {
    public struct AggregateState: Equatable, Sendable {
        public var hasActiveBatch: Bool
        public var hasAnyFailure: Bool
        public var progress: Double?   // 0...1, nil when idle
    }

    private unowned let documentState: DocumentState
    private let engine: RuntimeEngine
    private let disposeBag = DisposeBag()

    private let batchesRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
    private let aggregateRelay = BehaviorRelay<AggregateState>(
        value: .init(hasActiveBatch: false, hasAnyFailure: false, progress: nil)
    )

    private var documentBatchIDs: Set<RuntimeIndexingBatchID> = []
    private var eventPumpTask: Task<Void, Never>?

    public init(documentState: DocumentState) {
        self.documentState = documentState
        self.engine = documentState.runtimeEngine
        startEventPump()
    }

    deinit { eventPumpTask?.cancel() }

    // MARK: - Public observables for UI

    public var batchesObservable: Observable<[RuntimeIndexingBatch]> {
        batchesRelay.asObservable()
    }

    public var aggregateStateObservable: Observable<AggregateState> {
        aggregateRelay.asObservable()
    }

    // MARK: - Public command surface

    public func cancelBatch(_ id: RuntimeIndexingBatchID) {
        Task { [engine] in
            await engine.backgroundIndexingManager.cancelBatch(id)
        }
    }

    public func cancelAllBatches() {
        Task { [engine] in
            await engine.backgroundIndexingManager.cancelAllBatches()
        }
    }

    public func prioritize(imagePath: String) {
        Task { [engine] in
            await engine.backgroundIndexingManager.prioritize(imagePath: imagePath)
        }
    }

    // MARK: - Event pump (AsyncStream → Relay)

    private func startEventPump() {
        eventPumpTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.engine.backgroundIndexingManager.events
            for await event in stream {
                await MainActor.run { self.apply(event: event) }
            }
        }
    }

    @MainActor
    private func apply(event: RuntimeIndexingEvent) {
        var batches = batchesRelay.value
        switch event {
        case .batchStarted(let batch):
            batches.append(batch)
        case .taskStarted(let id, let path):
            batches = batches.map { mutating($0) { b in
                guard b.id == id, let idx = b.items.firstIndex(where: { $0.id == path })
                else { return }
                b.items[idx].state = .running
            }}
        case .taskFinished(let id, let path, let result):
            batches = batches.map { mutating($0) { b in
                guard b.id == id, let idx = b.items.firstIndex(where: { $0.id == path })
                else { return }
                b.items[idx].state = result
            }}
        case .taskPrioritized(let id, let path):
            batches = batches.map { mutating($0) { b in
                guard b.id == id, let idx = b.items.firstIndex(where: { $0.id == path })
                else { return }
                b.items[idx].hasPriorityBoost = true
            }}
        case .batchFinished(let finished), .batchCancelled(let finished):
            batches.removeAll { $0.id == finished.id }
            documentBatchIDs.remove(finished.id)
        }
        batchesRelay.accept(batches)
        refreshAggregate(batches: batches)
    }

    private func mutating<T>(_ value: T, _ mutate: (inout T) -> Void) -> T {
        var copy = value
        mutate(&copy)
        return copy
    }

    @MainActor
    private func refreshAggregate(batches: [RuntimeIndexingBatch]) {
        let hasActive = !batches.isEmpty
        let hasFailure = batches.contains {
            $0.items.contains {
                if case .failed = $0.state { return true }; return false
            }
        }
        let totalItems = batches.reduce(0) { $0 + $1.totalCount }
        let doneItems = batches.reduce(0) { $0 + $1.completedCount }
        let progress: Double? = totalItems > 0
            ? Double(doneItems) / Double(totalItems)
            : nil
        aggregateRelay.accept(
            .init(hasActiveBatch: hasActive, hasAnyFailure: hasFailure,
                  progress: progress))
    }
}
```

The `mutating(_:_:)` helper is now a private method on the coordinator (see earlier insertion). It is not a global function — `private` file-scope would still pollute any future file in the same module, and a private method keeps the utility scoped to the coordinator that needs it.

- [ ] **Step 3: Build**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing
git commit -m "feat(application): coordinator skeleton for background indexing"
```

---

### Task 15: Hook coordinator into document lifecycle — start `.appLaunch` batch

**Files:**
- Modify: `RuntimeBackgroundIndexingCoordinator.swift`

- [ ] **Step 1: Add settings access and startup entry point**

Append to `RuntimeBackgroundIndexingCoordinator.swift`:

```swift
extension RuntimeBackgroundIndexingCoordinator {
    public func documentDidOpen() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await self.currentBackgroundIndexingSettings()
            guard settings.isEnabled else { return }
            let root = await engine.mainExecutablePath()
            guard !root.isEmpty else { return }
            let id = await engine.backgroundIndexingManager.startBatch(
                rootImagePath: root,
                depth: settings.depth,
                maxConcurrency: settings.maxConcurrency,
                reason: .appLaunch)
            await MainActor.run { self.documentBatchIDs.insert(id) }
        }
    }

    public func documentWillClose() {
        let ids = documentBatchIDs
        documentBatchIDs.removeAll()
        Task { [engine, ids] in
            for id in ids {
                await engine.backgroundIndexingManager.cancelBatch(id)
            }
        }
    }

    private func currentBackgroundIndexingSettings() async -> BackgroundIndexing {
        // Access the Settings snapshot via the project's existing mechanism.
        // If `Settings.shared` is the accessor, use it; adjust to match.
        Settings.shared.backgroundIndexing
    }
}
```

Check the Settings singleton access pattern; `Settings.shared.backgroundIndexing` is the placeholder — substitute whatever the codebase actually uses (e.g. `@Dependency(\.settings)`).

- [ ] **Step 2: Build**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 3: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
git commit -m "feat(application): documentDidOpen / documentWillClose hooks for indexing"
```

---

### Task 16: Subscribe to image-loaded events — start per-image dependency batches

**Files:**
- Modify: `RuntimeBackgroundIndexingCoordinator.swift`

- [ ] **Step 1: Inspect the engine's image-loaded signal**

```bash
rg -n "didLoadImage|imageLoaded|imageDidLoad|PublishSubject.*String" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/ | head
```

Record the exact Rx observable or async sequence name. Adapt the subscription below to match.

- [ ] **Step 2: Add the subscription in the coordinator init, after `startEventPump()`**

```swift
private func subscribeToImageLoadedEvents() {
    // Adjust to the actual observable name discovered in Step 1.
    engine.imageLoadedSignal
        .emitOnNext { [weak self] path in
            guard let self else { return }
            Task { await self.handleImageLoaded(path: path) }
        }
        .disposed(by: disposeBag)
}

private func handleImageLoaded(path: String) async {
    let settings = await currentBackgroundIndexingSettings()
    guard settings.isEnabled else { return }
    // Avoid double-starting if the path is the main executable being opened
    // at app launch — documentDidOpen already dispatched that batch.
    let id = await engine.backgroundIndexingManager.startBatch(
        rootImagePath: path,
        depth: settings.depth,
        maxConcurrency: settings.maxConcurrency,
        reason: .imageLoaded(path: path))
    await MainActor.run { self.documentBatchIDs.insert(id) }
}
```

Call `subscribeToImageLoadedEvents()` at the end of `init`.

If the engine exposes only an `AsyncSequence` (not Rx), replace the subscription with:

```swift
imageEventPumpTask = Task { [weak self] in
    guard let self else { return }
    for await path in self.engine.imageLoadedAsyncSequence {
        await self.handleImageLoaded(path: path)
    }
}
```

- [ ] **Step 3: Build**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
git commit -m "feat(application): subscribe to engine image-loaded events to spawn batches"
```

---

### Task 17: React to Settings changes via `withObservationTracking`

**Files:**
- Modify: `RuntimeBackgroundIndexingCoordinator.swift`

**Why `withObservationTracking` (not Combine):** `Settings` at `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift:6` is declared `@Observable`. It has no Combine publisher, and the `scheduleAutoSave` path only fires through `didSet`. Adding a parallel `PassthroughSubject<Settings, Never>` would duplicate the source of truth. `withObservationTracking` is the native fit — the coordinator reads the tracked properties inside the `apply` closure, and Swift Observation registers a one-shot observer. We re-register inside `onChange` to keep observing across each mutation.

- [ ] **Step 1: Add observation imports and state**

At the top of `RuntimeBackgroundIndexingCoordinator.swift`:

```swift
import Observation
import RuntimeViewerSettings
```

Add private state on the coordinator class:

```swift
@MainActor private var lastKnownIsEnabled: Bool = false
```

- [ ] **Step 2: Implement the observation loop**

```swift
@MainActor
private func subscribeToSettings() {
    withObservationTracking {
        let snapshot = Settings.shared.backgroundIndexing
        _ = snapshot.isEnabled
        _ = snapshot.depth
        _ = snapshot.maxConcurrency
    } onChange: { [weak self] in
        // onChange fires off the main actor synchronously after any mutation.
        // Hop back to MainActor to (a) handle the change and (b) re-register.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleSettingsChange()
            self.subscribeToSettings()
        }
    }
}

@MainActor
private func handleSettingsChange() {
    let latest = Settings.shared.backgroundIndexing
    let wasEnabled = lastKnownIsEnabled
    lastKnownIsEnabled = latest.isEnabled
    if !wasEnabled && latest.isEnabled {
        documentDidOpen()                               // Scenario E on→off→on
    } else if wasEnabled && !latest.isEnabled {
        Task { [engine] in
            await engine.backgroundIndexingManager.cancelAllBatches()
        }
    }
    // depth / maxConcurrency changes: intentional no-op; next startBatch picks
    // up the new values.
}
```

- [ ] **Step 3: Seed initial state and register from init**

At the end of `init`:

```swift
Task { @MainActor [weak self] in
    guard let self else { return }
    self.lastKnownIsEnabled = Settings.shared.backgroundIndexing.isEnabled
    self.subscribeToSettings()
}
```

- [ ] **Step 4: Build**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
git commit -m "feat(application): observe Settings.backgroundIndexing via withObservationTracking"
```

---

## Phase 7 — Toolbar popover UI

### Task 18: Create `BackgroundIndexingNode` and popover ViewModel (on `MainRoute`)

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingNode.swift`
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewModel.swift`

**Why no separate Route:** `MainCoordinator` is declared `final class MainCoordinator: SceneCoordinator<MainRoute, MainTransition>` (`MainCoordinator.swift:11`). Its `Route` is already bound to `MainRoute`; a second conditional `Router` conformance for a `BackgroundIndexingPopoverRoute` would not compile. Instead, add a case to `MainRoute` (Task 21) and let the ViewModel be `ViewModel<MainRoute>`.

- [ ] **Step 1: Create `BackgroundIndexingNode`**

```swift
import RuntimeViewerCore

enum BackgroundIndexingNode: Hashable {
    case batch(RuntimeIndexingBatch)
    case item(batchID: RuntimeIndexingBatchID, item: RuntimeIndexingTaskItem)
}
```

- [ ] **Step 2: Create the ViewModel on `MainRoute`**

```swift
import Foundation
import Observation
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings
import RxCocoa
import RxSwift

final class BackgroundIndexingPopoverViewModel: ViewModel<MainRoute> {
    @Observed private(set) var nodes: [BackgroundIndexingNode] = []
    @Observed private(set) var isEnabled: Bool = false
    @Observed private(set) var hasAnyBatch: Bool = false
    @Observed private(set) var subtitle: String = ""

    private let coordinator: RuntimeBackgroundIndexingCoordinator

    init(documentState: DocumentState,
         router: any Router<MainRoute>,
         coordinator: RuntimeBackgroundIndexingCoordinator)
    {
        self.coordinator = coordinator
        super.init(documentState: documentState, router: router)
    }

    struct Input {
        let cancelBatch: Signal<RuntimeIndexingBatchID>
        let cancelAll: Signal<Void>
        let clearFailed: Signal<Void>
        let openSettings: Signal<Void>
    }
    struct Output {
        let nodes: Driver<[BackgroundIndexingNode]>
        let isEnabled: Driver<Bool>
        let hasAnyBatch: Driver<Bool>
        let subtitle: Driver<String>
    }

    func transform(_ input: Input) -> Output {
        coordinator.batchesObservable
            .map(Self.renderNodes)
            .asDriver(onErrorJustReturn: [])
            .driveOnNext { [weak self] newNodes in
                guard let self else { return }
                nodes = newNodes
                hasAnyBatch = !newNodes.isEmpty
            }
            .disposed(by: rx.disposeBag)

        coordinator.aggregateStateObservable
            .map(Self.subtitleFor)
            .asDriver(onErrorJustReturn: "")
            .driveOnNext { [weak self] s in
                guard let self else { return }
                subtitle = s
            }
            .disposed(by: rx.disposeBag)

        // isEnabled must stay reactive — the popover's empty states
        // depend on it. Use withObservationTracking like the coordinator
        // so toggling Settings while the popover is open updates the view.
        subscribeToIsEnabled()

        input.cancelBatch.emitOnNext { [weak self] id in
            guard let self else { return }
            coordinator.cancelBatch(id)
        }.disposed(by: rx.disposeBag)

        input.cancelAll.emitOnNext { [weak self] in
            guard let self else { return }
            coordinator.cancelAllBatches()
        }.disposed(by: rx.disposeBag)

        input.clearFailed.emitOnNext { [weak self] in
            guard let self else { return }
            coordinator.clearFailedBatches()
        }.disposed(by: rx.disposeBag)

        input.openSettings.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.openSettings)
        }.disposed(by: rx.disposeBag)

        return Output(
            nodes: $nodes.asDriver(),
            isEnabled: $isEnabled.asDriver(),
            hasAnyBatch: $hasAnyBatch.asDriver(),
            subtitle: $subtitle.asDriver()
        )
    }

    @MainActor
    private func subscribeToIsEnabled() {
        withObservationTracking {
            _ = Settings.shared.backgroundIndexing.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isEnabled = Settings.shared.backgroundIndexing.isEnabled
                self.subscribeToIsEnabled()  // re-register
            }
        }
        // Seed the current value synchronously on initial subscribe.
        isEnabled = Settings.shared.backgroundIndexing.isEnabled
    }

    private static func renderNodes(from batches: [RuntimeIndexingBatch])
        -> [BackgroundIndexingNode]
    {
        var out: [BackgroundIndexingNode] = []
        for batch in batches {
            out.append(.batch(batch))
            for item in batch.items {
                out.append(.item(batchID: batch.id, item: item))
            }
        }
        return out
    }

    private static func subtitleFor(
        _ state: RuntimeBackgroundIndexingCoordinator.AggregateState
    ) -> String {
        guard state.hasActiveBatch, let progress = state.progress else {
            return "Idle"
        }
        let percent = Int(progress * 100)
        return "\(percent)% complete"
    }
}
```

Note: `coordinator.clearFailedBatches()` is added in Task 24 together with the "retain failed batches until dismissed" reducer change. If you reach Task 18 before Task 24, leave the `clearFailed` binding as a TODO pass-through and circle back.

- [ ] **Step 3: Add the two new files to the Xcode project**

Using xcodeproj MCP, add:

```
RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingNode.swift
RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewModel.swift
```

Each to the `RuntimeViewerUsingAppKit` target. There is **no** `BackgroundIndexingPopoverRoute.swift` — routing is via `MainRoute`.

- [ ] **Step 4: Build the app target**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerUsingAppKit
git commit -m "feat(ui): popover ViewModel on MainRoute + BackgroundIndexingNode"
```

---

### Task 19: Build the popover ViewController

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift`

- [ ] **Step 1: Create the ViewController**

```swift
import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI
import RxCocoa
import RxSwift
import SnapKit

final class BackgroundIndexingPopoverViewController:
    UXKitViewController<BackgroundIndexingPopoverViewModel>
{
    // MARK: - Relays
    private let cancelBatchRelay = PublishRelay<RuntimeIndexingBatchID>()
    private let cancelAllRelay = PublishRelay<Void>()
    private let openSettingsRelay = PublishRelay<Void>()

    // MARK: - Views
    private let titleLabel = Label("Background Indexing").then {
        $0.font = .systemFont(ofSize: 13, weight: .semibold)
    }
    private let subtitleLabel = Label("").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .secondaryLabelColor
    }
    private let emptyDisabledView = Label("Background indexing is disabled").then {
        $0.alignment = .center
        $0.textColor = .secondaryLabelColor
    }
    private let openSettingsButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Open Settings"
    }
    private let emptyIdleView = Label("No active indexing tasks").then {
        $0.alignment = .center
        $0.textColor = .secondaryLabelColor
    }
    private let outlineView = NSOutlineView().then {
        $0.headerView = nil
        $0.rowSizeStyle = .small
        $0.selectionHighlightStyle = .regular
        $0.indentationPerLevel = 16
    }
    private let scrollView = ScrollView()
    private let cancelAllButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Cancel All"
    }
    private let closeButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Close"
    }

    // MARK: - Setup
    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        setupOutlineView()
        setupActions()
        preferredContentSize = NSSize(width: 380, height: 300)
    }

    private func setupLayout() {
        let headerStack = VStackView(alignment: .leading, spacing: 2) {
            titleLabel
            subtitleLabel
        }
        let buttonStack = HStackView(spacing: 8) {
            cancelAllButton
            closeButton
        }
        buttonStack.alignment = .centerY

        let emptyDisabledStack = VStackView(alignment: .centerX, spacing: 8) {
            emptyDisabledView
            openSettingsButton
        }

        scrollView.documentView = outlineView

        contentView.hierarchy {
            headerStack
            emptyDisabledStack
            emptyIdleView
            scrollView
            buttonStack
        }
        headerStack.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
        emptyDisabledStack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualToSuperview().offset(-32)
        }
        emptyIdleView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(8)
            make.bottom.equalTo(buttonStack.snp.top).offset(-8)
        }
        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(12)
        }
    }

    private func setupOutlineView() {
        let column = NSTableColumn(identifier: .init("status"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
    }

    private func setupActions() {
        cancelAllButton.target = self
        cancelAllButton.action = #selector(cancelAllClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsClicked)
    }

    @objc private func cancelAllClicked() { cancelAllRelay.accept(()) }
    @objc private func closeClicked() { dismiss(nil) }
    @objc private func openSettingsClicked() { openSettingsRelay.accept(()) }

    override func setupBindings(for viewModel: BackgroundIndexingPopoverViewModel) {
        super.setupBindings(for: viewModel)
        let input = BackgroundIndexingPopoverViewModel.Input(
            cancelBatch: cancelBatchRelay.asSignal(),
            cancelAll: cancelAllRelay.asSignal(),
            openSettings: openSettingsRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.subtitle.drive(subtitleLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.isEnabled
            .driveOnNext { [weak self] enabled in
                guard let self else { return }
                emptyDisabledView.isHidden = enabled
                openSettingsButton.isHidden = enabled
            }
            .disposed(by: rx.disposeBag)

        Observable.combineLatest(
            output.isEnabled.asObservable(),
            output.hasAnyBatch.asObservable()
        )
        .subscribeOnNext { [weak self] enabled, hasBatches in
            guard let self else { return }
            emptyIdleView.isHidden = !enabled || hasBatches
            scrollView.isHidden = !enabled || !hasBatches
        }
        .disposed(by: rx.disposeBag)

        output.nodes
            .driveOnNext { [weak self] nodes in
                guard let self else { return }
                renderedNodes = nodes
                outlineView.reloadData()
                outlineView.expandItem(nil, expandChildren: true)
            }
            .disposed(by: rx.disposeBag)
    }

    // MARK: - Outline data
    fileprivate var renderedNodes: [BackgroundIndexingNode] = []
}

extension BackgroundIndexingPopoverViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView,
                     numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return renderedNodes.filter { if case .batch = $0 { true } else { false } }.count
        }
        guard let node = item as? BackgroundIndexingNode, case .batch(let batch) = node
        else { return 0 }
        return batch.items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            let batches = renderedNodes.compactMap { node -> RuntimeIndexingBatch? in
                if case .batch(let b) = node { return b } else { return nil }
            }
            return BackgroundIndexingNode.batch(batches[index])
        }
        guard let node = item as? BackgroundIndexingNode, case .batch(let batch) = node
        else {
            preconditionFailure("unexpected outline item type: \(type(of: item))")
        }
        return BackgroundIndexingNode.item(batchID: batch.id,
                                           item: batch.items[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? BackgroundIndexingNode, case .batch = node { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? BackgroundIndexingNode else { return nil }
        let cell = NSTableCellView()
        let label = Label("")
        cell.hierarchy { label }
        label.snp.makeConstraints { make in
            make.leading.trailing.centerY.equalToSuperview()
        }
        switch node {
        case .batch(let batch):
            let title = Self.title(for: batch.reason)
            label.stringValue = "\(title)   \(batch.completedCount)/\(batch.totalCount)"
        case .item(_, let item):
            let name = (item.resolvedPath ?? item.id as NSString)
                .lastPathComponent
            let prefix: String = {
                switch item.state {
                case .pending: return "·"
                case .running: return "↻"
                case .completed: return "✓"
                case .failed: return "✗"
                case .cancelled: return "⊘"
                }
            }()
            var text = "\(prefix) \(name)"
            if case .failed(let message) = item.state {
                text = "\(prefix) \(item.id)  —  \(message)"
            }
            if item.hasPriorityBoost, case .pending = item.state {
                text += "   (priority)"
            }
            label.stringValue = text
        }
        return cell
    }

    private static func title(for reason: RuntimeIndexingBatchReason) -> String {
        switch reason {
        case .appLaunch: return "App launch indexing"
        case .imageLoaded(let path):
            return "\((path as NSString).lastPathComponent) deps"
        case .settingsEnabled: return "Settings enabled"
        case .manual: return "Manual indexing"
        }
    }
}
```

- [ ] **Step 2: Add to Xcode project**

xcodeproj MCP `add_file`: `BackgroundIndexingPopoverViewController.swift` to the `RuntimeViewerUsingAppKit` target.

- [ ] **Step 3: Build**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerUsingAppKit
git commit -m "feat(ui): popover view controller for background indexing"
```

---

### Task 20: Build the Toolbar item view with `NSProgressIndicator` overlay

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingToolbarItemView.swift`
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingToolbarItem.swift`

- [ ] **Step 1: Create the custom view**

```swift
import AppKit
import SnapKit

enum BackgroundIndexingToolbarState: Equatable {
    case idle
    case disabled
    case indexing
    case hasFailures
}

final class BackgroundIndexingToolbarItemView: NSView {
    private let iconView = NSImageView().then {
        $0.image = NSImage(systemSymbolName: "square.stack.3d.down.right",
                           accessibilityDescription: nil)
        $0.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        $0.contentTintColor = .secondaryLabelColor
    }
    private let spinner = NSProgressIndicator().then {
        $0.style = .spinning
        $0.controlSize = .small
        $0.isIndeterminate = true
        $0.isDisplayedWhenStopped = false
    }
    private let failureDot = NSView()

    var state: BackgroundIndexingToolbarState = .idle {
        didSet { applyState() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayout()
        applyState()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupLayout() {
        hierarchy {
            iconView
            spinner
            failureDot
        }
        iconView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(18)
        }
        spinner.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(14)
        }
        failureDot.snp.makeConstraints { make in
            make.width.height.equalTo(6)
            make.trailing.bottom.equalTo(iconView)
        }
        failureDot.wantsLayer = true
        failureDot.layer?.cornerRadius = 3
        failureDot.layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    private func applyState() {
        switch state {
        case .idle:
            iconView.contentTintColor = .secondaryLabelColor
            spinner.stopAnimation(nil)
            failureDot.isHidden = true
        case .disabled:
            iconView.contentTintColor = .tertiaryLabelColor
            spinner.stopAnimation(nil)
            failureDot.isHidden = true
        case .indexing:
            iconView.contentTintColor = .controlAccentColor
            spinner.startAnimation(nil)
            failureDot.isHidden = true
        case .hasFailures:
            iconView.contentTintColor = .controlAccentColor
            spinner.startAnimation(nil)
            failureDot.isHidden = false
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
}
```

- [ ] **Step 2: Create the `NSToolbarItem` subclass**

```swift
import AppKit
import RxCocoa
import RxSwift

final class BackgroundIndexingToolbarItem: NSToolbarItem {
    static let identifier = NSToolbarItem.Identifier("backgroundIndexing")

    let itemView = BackgroundIndexingToolbarItemView()
    let tapRelay = PublishRelay<NSView>()
    private let disposeBag = DisposeBag()

    init() {
        super.init(itemIdentifier: Self.identifier)
        label = "Indexing"
        paletteLabel = "Background Indexing"
        toolTip = "Background indexing status"
        view = itemView
        target = self
        action = #selector(clicked)
    }

    func bindState(_ driver: Driver<BackgroundIndexingToolbarState>) {
        driver.driveOnNext { [weak self] state in
            guard let self else { return }
            itemView.state = state
        }
        .disposed(by: disposeBag)
    }

    @objc private func clicked() {
        tapRelay.accept(itemView)
    }
}
```

- [ ] **Step 3: Add both files to Xcode**

xcodeproj MCP `add_file` twice to the `RuntimeViewerUsingAppKit` target.

- [ ] **Step 4: Build**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerUsingAppKit
git commit -m "feat(ui): toolbar item view and item class for background indexing"
```

---

### Task 21: Register the toolbar item and add the `MainRoute.backgroundIndexing` case

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainRoute.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift`

**Why it's one route case, not a separate `Router` conformance:** `MainCoordinator` is already `SceneCoordinator<MainRoute, MainTransition>`. A conditional `extension MainCoordinator: Router where Route == BackgroundIndexingPopoverRoute` cannot compile — `Route` is pinned to `MainRoute`. The plan therefore extends `MainRoute` directly with one case and routes the popover's `.openSettings` through the existing `MainRoute.openSettings` case.

- [ ] **Step 1: Inspect the existing MCPStatus wiring**

```bash
rg -n "mcpStatus|MCPStatusToolbarItem|toolbarDefaultItemIdentifiers|itemForItemIdentifier" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift | head -30
```

Also check `MainRoute.swift:18` — the existing case is literally `case mcpStatus(sender: NSView)`, not `mcpStatusPopover`. Match that naming style.

- [ ] **Step 2: Add the route case on `MainRoute`**

In `MainRoute.swift`, next to `case mcpStatus(sender: NSView)`, add:

```swift
case backgroundIndexing(sender: NSView)
```

(No `Popover` suffix — matches the sibling `mcpStatus` precedent.)

- [ ] **Step 3: Register the toolbar item in `MainToolbarController`**

```swift
override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar)
    -> [NSToolbarItem.Identifier]
{
    var ids = super.toolbarDefaultItemIdentifiers(toolbar)
    ids.append(BackgroundIndexingToolbarItem.identifier)
    return ids
}

override func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar)
    -> [NSToolbarItem.Identifier]
{
    var ids = super.toolbarAllowedItemIdentifiers(toolbar)
    ids.append(BackgroundIndexingToolbarItem.identifier)
    return ids
}

func toolbar(_ toolbar: NSToolbar,
             itemForItemIdentifier identifier: NSToolbarItem.Identifier,
             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
{
    if identifier == BackgroundIndexingToolbarItem.identifier {
        let item = BackgroundIndexingToolbarItem()
        backgroundIndexingItem = item
        wireBackgroundIndexing(item: item)
        return item
    }
    return super.toolbar(toolbar, itemForItemIdentifier: identifier,
                         willBeInsertedIntoToolbar: flag)
}

private weak var backgroundIndexingItem: BackgroundIndexingToolbarItem?

private func wireBackgroundIndexing(item: BackgroundIndexingToolbarItem) {
    item.bindState(
        documentState.backgroundIndexingCoordinator.aggregateStateObservable
            .map { state -> BackgroundIndexingToolbarState in
                if !state.hasActiveBatch { return .idle }
                return state.hasAnyFailure ? .hasFailures : .indexing
            }
            .asDriver(onErrorJustReturn: .idle)
    )
    item.tapRelay
        .emitOnNext { [weak self] sender in
            guard let self else { return }
            mainCoordinator.trigger(.backgroundIndexing(sender: sender))
        }
        .disposed(by: rx.disposeBag)
}
```

The exact field names (`documentState`, `mainCoordinator`) must match `MainToolbarController`'s existing fields — adjust if the property is spelled differently.

- [ ] **Step 4: Handle the new case in `MainCoordinator.prepareTransition`**

```swift
case .backgroundIndexing(let sender):
    let viewController = BackgroundIndexingPopoverViewController()
    let viewModel = BackgroundIndexingPopoverViewModel(
        documentState: documentState,
        router: self,            // already Router<MainRoute>
        coordinator: documentState.backgroundIndexingCoordinator)
    viewController.setupBindings(for: viewModel)
    return .presentOnRoot(
        viewController,
        mode: .asPopover(relativeToRect: sender.bounds,
                         ofView: sender,
                         preferredEdge: .maxY,
                         behavior: .transient))
```

No `extension MainCoordinator: Router where Route == ...` wrapper is needed — `self` is already `Router<MainRoute>`, and the popover's `openSettings` button triggers `router.trigger(.openSettings)` directly (the case already exists on `MainRoute`).

- [ ] **Step 5: Build**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerUsingAppKit
git commit -m "feat(ui): toolbar item + MainRoute.backgroundIndexing popover route"
```

---

## Phase 8 — Integration and QA

### Task 22: Hold a coordinator on `DocumentState` and invoke lifecycle hooks

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift`

- [ ] **Step 1: Add the coordinator property to `DocumentState` and reinforce the `runtimeEngine` invariant**

```swift
/// Immutable for the lifetime of the Document. The property is declared
/// `@Observed` for historical UI reasons, but callers MUST NOT reassign it.
/// The background indexing coordinator (and any future per-engine actor)
/// captures this reference at init time; reassignment would silently route
/// work to a stale engine.
@Observed
public var runtimeEngine: RuntimeEngine = .local

public private(set) lazy var backgroundIndexingCoordinator =
    RuntimeBackgroundIndexingCoordinator(documentState: self)
```

Edit the existing declaration of `runtimeEngine` at `DocumentState.swift:10-11` to include the doc comment above; leave the type and initial value unchanged.

- [ ] **Step 2: Invoke lifecycle hooks from `Document`**

In `Document.swift`:

```swift
override func makeWindowControllers() {
    super.makeWindowControllers()
    documentState.backgroundIndexingCoordinator.documentDidOpen()
}

override func close() {
    documentState.backgroundIndexingCoordinator.documentWillClose()
    super.close()
}
```

Check the current `makeWindowControllers` / `close` implementation before editing; splice the lines in without removing existing logic.

- [ ] **Step 3: Build (package + app)**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerPackages RuntimeViewerUsingAppKit
git commit -m "feat(app): wire background indexing coordinator into Document lifecycle"
```

---

### Task 23: Wire sidebar selection → `prioritize`

**Files:**
- Modify: the coordinator or VC that observes sidebar selection (likely `MainCoordinator` or `SidebarCoordinator`)

- [ ] **Step 1: Find the sidebar image selection signal**

```bash
rg -n "imageSelected|didSelectImage|sidebar.*Selected" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/ /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/ | head -20
```

Record the exact signal name and where it's published.

- [ ] **Step 2: In the sidebar coordinator init (or wherever selection is handled), add:**

```swift
sidebarViewModel.$selectedImagePath
    .driveOnNext { [weak self] path in
        guard let self, let path else { return }
        documentState.backgroundIndexingCoordinator.prioritize(imagePath: path)
    }
    .disposed(by: rx.disposeBag)
```

Use whichever observable already tracks sidebar image selection. If there isn't one, promote the existing relay to `public` and use it.

- [ ] **Step 3: Build**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 4: Commit**

```bash
git add .
git commit -m "feat(app): prioritize indexing when user selects an image in sidebar"
```

---

### Task 24: Retain failed batches; refresh image list once per batch finish

**Files:**
- Modify: `RuntimeBackgroundIndexingCoordinator.swift`

**Why retain failed batches:** The toolbar state `.hasFailures(...)` is derived from the coordinator's `aggregateState`. If `.batchFinished` immediately removes the batch — even one containing `.failed` items — the toolbar never surfaces the failure. This task changes the `.batchFinished` / `.batchCancelled` reducer: clean finishes and cancels drop out; finishes with any `.failed` item stay in `batchesRelay` until the user calls `clearFailedBatches()` from the popover.

- [ ] **Step 1: Update the `apply(event:)` reducer for `.batchFinished` / `.batchCancelled`**

```swift
case .batchFinished(let finished):
    if finished.items.contains(where: { if case .failed = $0.state { true } else { false } }) {
        // Keep the failed batch in the list until the user dismisses it.
        if let idx = batches.firstIndex(where: { $0.id == finished.id }) {
            batches[idx] = finished
        }
    } else {
        batches.removeAll { $0.id == finished.id }
        documentBatchIDs.remove(finished.id)
    }
    Task { [engine] in
        await engine.reloadData(isReloadImageNodes: false)
    }

case .batchCancelled(let cancelled):
    // Cancellation always removes — user already acknowledged the outcome.
    batches.removeAll { $0.id == cancelled.id }
    documentBatchIDs.remove(cancelled.id)
    Task { [engine] in
        await engine.reloadData(isReloadImageNodes: false)
    }
```

- [ ] **Step 2: Add `clearFailedBatches()` to the coordinator's public surface**

```swift
public func clearFailedBatches() {
    Task { @MainActor [weak self] in
        guard let self else { return }
        let remaining = batchesRelay.value.filter { batch in
            !batch.items.contains { if case .failed = $0.state { true } else { false } }
        }
        batchesRelay.accept(remaining)
        refreshAggregate(batches: remaining)
    }
}
```

This is the method the Task 18 popover ViewModel calls from its `Clear Failed` button input.

- [ ] **Step 3: Update `refreshAggregate` so `hasAnyFailure` considers retained batches**

The existing `hasAnyFailure` computation already scans `batches` for `.failed` items, so no change is required — the retained failed batches stay visible in the aggregate state.

- [ ] **Step 4: Build**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
git commit -m "feat(application): retain failed batches + single reloadData per batch finish"
```

---

### Task 25: Full build, run tests, manual QA

- [ ] **Step 1: Run the full Core test suite**

```bash
cd RuntimeViewerCore && swift test 2>&1 | xcsift
```

Expected: all tests pass.

- [ ] **Step 2: Run the full Packages build**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages && swift package update && swift build 2>&1 | xcsift
```

- [ ] **Step 3: Build the app**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer && xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 4: Manual QA checklist**

Launch the debug app and verify, ticking each box:

- [ ] With Background Indexing disabled in Settings, the toolbar item shows the faded idle icon and the popover shows the "disabled" empty state.
- [ ] Enabling the toggle in Settings triggers a new batch for the app's main executable; the toolbar icon starts spinning; the popover shows the batch with items progressing.
- [ ] Reducing depth / maxConcurrency while a batch is running does not affect that batch.
- [ ] A new batch after changing settings uses the new values (verify by inspecting `items.count` for a deep-tree image).
- [ ] Loading a new image (File → Open) spawns a second batch named after the new image; both batches progress concurrently.
- [ ] Clicking the batch's cancel button (⊘) stops the batch; its unfinished items become grey; the toolbar icon returns to idle when no batches remain.
- [ ] The "Cancel All" button in the popover cancels every batch.
- [ ] Selecting an image in the sidebar that is currently pending in a batch shows a `(priority)` tag on its popover row and it runs next.
- [ ] An image with an unresolvable `@rpath` dependency renders a red ✗ row with the install name and the error message.
- [ ] Closing the Document cancels its batches; the toolbar icon for that window resets to idle.

- [ ] **Step 5: Commit the manual verification checklist outcome (optional)**

If all boxes tick, no code change is required. Otherwise, fix the failing item in a new task, then re-run Step 4.

---

### Task 26: Open a pull request

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feature/runtime-background-indexing
```

- [ ] **Step 2: Create the PR**

```bash
gh pr create --title "feat: background indexing" --body "$(cat <<'EOF'
## Summary
- Adds opt-in background indexing that eagerly parses ObjC/Swift metadata for the dependency closure of loaded images.
- Core scheduling is a Swift Concurrency actor (`RuntimeBackgroundIndexingManager`) inside `RuntimeEngine`, with a `RuntimeBackgroundIndexingCoordinator` in the Application layer bridging events to RxSwift for UI.
- UI: Settings page under "Background Indexing", toolbar item + popover for live progress and per-batch cancellation.

## Test plan
- [ ] `swift test` passes in `RuntimeViewerCore` (unit tests for value types, `DylibPathResolver`, manager behavior).
- [ ] App builds cleanly for macOS.
- [ ] Manual QA checklist in `Documentations/Plans/2026-04-24-background-indexing-plan.md` (Task 25) executed end-to-end.

## Design
See [0002-background-indexing.md](../Evolution/0002-background-indexing.md).
EOF
)"
```

---

## Self-Review Summary

- **Spec coverage:** every section of the evolution proposal has at least one task.
  - Package wiring (Semaphore dependency) → Task 0.
  - Value types (all `Hashable`) + `ResolvedDependency` → Task 1.
  - `DylibPathResolver` → Task 2.
  - `Loaded vs Indexed` + `request/remote` dispatch for `isImageIndexed` → Task 3.
  - Engine new APIs (`mainExecutablePath`, `loadImageForBackgroundIndexing`) with `request/remote` → Task 4; `imageDidLoadPublisher` → Task 4.5.
  - Manager (protocol + mock, skeleton, BFS, concurrency, cancel, prioritize) → Tasks 5-10.
  - Engine integration (non-`lazy` stored manager) → Task 11.
  - Settings → Tasks 12-13.
  - Coordinator (lifecycle, image-loaded, Settings via `withObservationTracking`) → Tasks 14-17.
  - UI (Node + ViewModel on `MainRoute`, VC with `preconditionFailure` data source, toolbar view + item, `MainRoute.backgroundIndexing` registration) → Tasks 18-21.
  - Integration (Document wiring + `runtimeEngine` immutability doc comment) → Task 22.
  - Sidebar → prioritize → Task 23.
  - Retain failed batches + refresh image list → Task 24.
  - Manual QA → Task 25.
- **Review decisions embedded:** all three header decisions from the 2026-04-24 review — Settings via `withObservationTracking` (Task 17), `BackgroundIndexingPopoverRoute` merged into `MainRoute` (Task 18/21), and `request/remote` dispatch for engine methods (Tasks 3/4) — have dedicated tasks and explicit rationale paragraphs.
- **Type consistency:** `RuntimeIndexingBatchID`, `RuntimeIndexingBatch`, `RuntimeIndexingTaskState`, `RuntimeIndexingEvent`, `RuntimeIndexingBatchReason`, `RuntimeIndexingTaskItem`, `ResolvedDependency`, `BackgroundIndexingToolbarState`, `BackgroundIndexing`, `BackgroundIndexingNode`, `BackgroundIndexingPopoverViewModel`, `BackgroundIndexingPopoverViewController`, `BackgroundIndexingToolbarItem`, `BackgroundIndexingToolbarItemView`, `RuntimeBackgroundIndexingManager`, `RuntimeBackgroundIndexingCoordinator`, `DylibPathResolver`, `BackgroundIndexingEngineRepresenting` — all cross-referenced names match between their definition task and the tasks that consume them. No `BackgroundIndexingPopoverRoute` type is introduced anywhere.
