# 后台索引实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标:** 按 [0002-background-indexing.md](../Evolution/0002-background-indexing.md) 构建可选的后台索引功能 —— 一个每 `RuntimeEngine` 一份的 Swift Concurrency `RuntimeBackgroundIndexingManager` actor、Settings 控件以及一个 Toolbar 弹出框。

**架构:** 所有核心逻辑置于 `RuntimeViewerCore`（带 `Runtime` 前缀）；coordinator 置于 `RuntimeViewerApplication`（带 `Runtime` 前缀）；UI 置于 `RuntimeViewerUsingAppKit`；Settings UI 置于 `RuntimeViewerSettingsUI`（后两者均不带前缀）。所有任务调度采用 Swift Concurrency；RxSwift 仅用于 coordinator 中的 UI 绑定。

**技术栈:** Swift 5（语言模式 v5）、Swift Concurrency（actor / AsyncStream / TaskGroup）、AsyncSemaphore（groue/Semaphore，已解析）、MachOKit（MachOImage.dependencies）、RxSwift/RxCocoa、SnapKit、AppKit、SwiftUI（仅 Settings）、MetaCodable `@Codable`、swift-memberwise-init-macro `@MemberInit`。

---

## 全文通用约定

- **构建 / 测试命令**: 所有 `swift build` / `swift test` 调用都先运行 `swift package update`，并按项目 CLAUDE.md 通过 `xcsift` 管道。在 package 目录（`RuntimeViewerCore/` 或 `RuntimeViewerPackages/`）下运行。
- **提交风格**: 使用 Conventional Commits（`feat:`、`test:`、`refactor:`、`docs:`），匹配近期项目历史。
- **`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/` 下每个新文件**都必须加入 `RuntimeViewer.xcodeproj` —— 按集成任务中所示使用 xcodeproj MCP（`add_file`）。其他 packages（`RuntimeViewerCore`、`RuntimeViewerPackages`）是 SPM，新源文件会被自动识别。
- **命名**: 在 `RuntimeViewerCore` 与 `RuntimeViewerApplication` 中创建的类型带 `Runtime` 前缀。在 `RuntimeViewerUsingAppKit`、`RuntimeViewerSettingsUI`、`RuntimeViewerSettings` 中创建的类型**不带**前缀（与 `MCP` / `MCPSettingsView` 先例保持一致）。
- **访问控制**: 默认 `private`；仅在调用方需要时放宽。ViewModel 上的可观察状态：`@Observed private(set) var`。
- **weak self 习惯**: `guard let self else { return }` —— 不用 `strongSelf`，不用 `if let self`。
- **RxSwift 订阅风格**: 仅使用尾随闭包变体（`.driveOnNext { }`、`.emitOnNext { }`、`.subscribeOnNext { }`）。
- **分支**: 所有工作发生在 `feature/runtime-background-indexing`（已从 `origin/main` 创建）。

---

## Phase 0 —— Package 接线

### 任务 0: 将 Semaphore 声明为 `RuntimeViewerCore` 的显式依赖

**文件:**
- 修改: `RuntimeViewerCore/Package.swift`

**为什么:** `groue/Semaphore` 包已经为 `RuntimeViewerCommunication` target 解析（参见 `Package.swift:163`），但 `RuntimeViewerCore` 自身的 target 并未声明。`RuntimeBackgroundIndexingManager.swift`（任务 6）会 `import Semaphore`；依赖传递可见性是脆弱的（一旦启用 `.memberImportVisibility` 就会失效，而该选项已经在 `Package.swift:200` 定义）。在任何代码使用之前先把依赖显式化。

- [ ] **Step 1: 编辑 `RuntimeViewerCore` target 的 `dependencies` 数组**

在 `RuntimeViewerCore/Package.swift` 的 `.target(name: "RuntimeViewerCore", dependencies: [...])`（当前行 142-157）内，在已有的 `MetaCodable` 产品之后追加：

```swift
.product(name: "Semaphore", package: "Semaphore"),
```

- [ ] **Step 2: 解析并构建**

```bash
cd RuntimeViewerCore && swift package update && swift build 2>&1 | xcsift
```

预期：构建无报错（尚未变更代码）。

- [ ] **Step 3: 提交**

```bash
git add RuntimeViewerCore/Package.swift
git commit -m "chore(core): add Semaphore as explicit RuntimeViewerCore dependency"
```

---

## Phase 1 —— 基础值类型

### 任务 1: 为索引事件与批次创建 Sendable + Hashable 值类型

**文件:**
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingBatchID.swift`
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingBatchReason.swift`
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingTaskState.swift`
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingTaskItem.swift`
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingBatch.swift`
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeIndexingEvent.swift`
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/ResolvedDependency.swift`
- 测试: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeIndexingValueTypesTests.swift`

**为什么处处都是 Hashable:** `BackgroundIndexingNode`（任务 18）声明为 `Hashable`，以便用作 `NSOutlineView` / `NSDiffableDataSource` 的更新键。它的关联值需要传递性的 `Hashable`。提前声明比后续补回更便宜。

- [ ] **Step 1: 写出针对值类型不变量的失败测试**

文件 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeIndexingValueTypesTests.swift`:

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
        XCTAssertEqual(batch.completedCount, 3)   // completed + failed 都计入"完成"
        XCTAssertEqual(batch.totalCount, 4)
    }
}
```

- [ ] **Step 2: 运行测试 —— 预期编译失败**

```bash
cd RuntimeViewerCore && swift package update && swift test --filter RuntimeIndexingValueTypesTests 2>&1 | xcsift
```

预期：所有引用类型出现编译错误。

- [ ] **Step 3: 创建值类型文件**

文件 `RuntimeIndexingBatchID.swift`:

```swift
import Foundation

public struct RuntimeIndexingBatchID: Hashable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}
```

文件 `RuntimeIndexingBatchReason.swift`:

```swift
public enum RuntimeIndexingBatchReason: Sendable, Hashable {
    case appLaunch
    case imageLoaded(path: String)
    case settingsEnabled
    case manual
}
```

文件 `RuntimeIndexingTaskState.swift`:

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

文件 `RuntimeIndexingTaskItem.swift`:

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

文件 `ResolvedDependency.swift`:

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

文件 `RuntimeIndexingBatch.swift`:

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

文件 `RuntimeIndexingEvent.swift`:

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

- [ ] **Step 4: 运行测试 —— 预期通过**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeIndexingValueTypesTests 2>&1 | xcsift
```

预期：6 个测试通过。

- [ ] **Step 5: 提交**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing
git commit -m "feat(core): add Sendable value types for background indexing"
```

---

### 任务 2: 实现 `DylibPathResolver`

**文件:**
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DylibPathResolver.swift`
- 测试: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/DylibPathResolverTests.swift`

- [ ] **Step 1: 探索 `MachOImage` 上的 `LC_RPATH` / 可执行路径 API**

```bash
rg -n "rpaths|LC_RPATH|executablePath|loaderPath" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/MachOKit/Sources/MachOKit/ --type swift | head
```

记录哪个 `MachOImage` 属性暴露了 `LC_RPATH` 条目（预期 `rpaths: [String]`），以及是否有获取主可执行文件路径的辅助函数（预期 `_dyld_get_image_name(0)`）。在你的草稿笔记中记下发现 —— 下面的 resolver 设计假设 `image.rpaths: [String]`。

如果 API 名称不同（例如 `rpathCommands` 返回 `RpathCommand` 项，其 `.path` 给出原始字符串），按需在 Step 3 中调整 resolver 代码。

- [ ] **Step 2: 写出失败测试**

文件 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/DylibPathResolverTests.swift`:

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

- [ ] **Step 3: 实现 resolver**

文件 `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DylibPathResolver.swift`:

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

- [ ] **Step 4: 运行测试 —— 预期通过**

```bash
cd RuntimeViewerCore && swift test --filter DylibPathResolverTests 2>&1 | xcsift
```

预期：6 个测试通过。

- [ ] **Step 5: 提交**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DylibPathResolver.swift RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/DylibPathResolverTests.swift
git commit -m "feat(core): add DylibPathResolver for @rpath / @executable_path / @loader_path"
```

---

## Phase 2 —— Engine 扩展

### 任务 3: 在两个 section factory 上暴露 `hasCachedSection`；在 engine 上加 `isImageIndexed`，使用 `request/remote` 分发

**文件:**
- 修改: `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift`（factory 区域）
- 修改: `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift`（factory 区域）
- 修改: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`（factory 提升至 `internal`；`CommandNames` 加 `.isImageIndexed`；注册处理器）
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift`
- 测试: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeEngineIndexStateTests.swift`

**为什么要 `request/remote`:** 当文档目标是远程源（XPC / directTCP）时，本地 engine 的 factory 缓存为空 —— 只有服务进程拥有真相。每一个已有的 engine 公共方法都使用 `request<T>(local:remote:)` 原语（`RuntimeEngine.swift:468`）；这里跳过会让远程源返回错误数据。

- [ ] **Step 1: 阅读 factory 类以了解缓存结构**

```bash
rg -n "class RuntimeObjCSectionFactory|class RuntimeSwiftSectionFactory|private var sections|func section\(for" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/
```

记录：缓存存储变量名（预期 `sections: [String: RuntimeObjCSection]` / 类似），以及 factory 是否已经缓存 nil 结果。如果不缓存 nil，下面引入的 `hasCachedSection` 谓词体现"成功解析" —— 对 MVP 而言可以接受，因为 `.failed` 任务项会捕获失败情况。

- [ ] **Step 2: 写出 `isImageIndexed` 的失败测试**

文件 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeEngineIndexStateTests.swift`:

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

- [ ] **Step 3: 在每个 factory 上添加 `hasCachedSection(for:)`**

在 `RuntimeObjCSection.swift` 的 `RuntimeObjCSectionFactory` 内：

```swift
func hasCachedSection(for path: String) -> Bool {
    sections[path] != nil
}
```

在 `RuntimeSwiftSection.swift`，相同模式：

```swift
func hasCachedSection(for path: String) -> Bool {
    sections[path] != nil
}
```

匹配 Step 1 中观察到的精确存储名。如果 factory 使用 `cache` 或 `_sections`，请相应替换。

- [ ] **Step 4: 放宽 factory 与 `request<T>` 分发原语的访问级别（必做）**

`RuntimeEngine.swift:147-149` 当前将两个 factory 都声明为 `private`：

```swift
private let objcSectionFactory: RuntimeObjCSectionFactory
private let swiftSectionFactory: RuntimeSwiftSectionFactory
```

`RuntimeEngine.swift:468` 当前将 `request<T>` 也声明为 `private`：

```swift
private func request<T>(local: () async throws -> T,
                        remote: (_ senderConnection: RuntimeConnection) async throws -> T)
    async throws -> T { ... }
```

将这三处 **全部** 改为 `internal`（去掉 `private` 关键字；默认即 `internal`）。下面 Step 6 / 任务 4 / 任务 4.5 创建的 `RuntimeEngine+BackgroundIndexing.swift` 扩展位于 **不同文件**，Swift 的 `private` 不允许跨文件 extension 访问 —— 即便在同一类型同一 module。`request<T>` 与两个 factory 都会被那个扩展引用，必须提至 `internal`。已经核验过当前代码 —— 这三处现在均为 `private`。

- [ ] **Step 5: 在 `CommandNames` 中加 `.isImageIndexed` 并注册服务端处理器**

在 `RuntimeEngine.swift` 中找到 `CommandNames` 枚举（约第 62 行）。添加：

```swift
case isImageIndexed
```

在第 276 行附近的 `setMessageHandlerBinding(...)` 块中添加：

```swift
setMessageHandlerBinding(forName: .isImageIndexed, of: self) { $0.isImageIndexed(path:) }
```

正好和已有的 `.isImageLoaded` 绑定相邻。

- [ ] **Step 6: 创建使用 `request/remote` 分发的 engine 扩展**

文件 `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift`:

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

注意：上面 Step 2 中的测试已更新为 `try await engine.isImageIndexed(path:)`，因为该方法现在 throws。

- [ ] **Step 7: 运行测试 —— 预期通过**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeEngineIndexStateTests 2>&1 | xcsift
```

预期：2 个测试通过。第二个测试依赖真实的 Foundation 镜像；如果 CI 中没有此精确路径，注释掉第二个测试并留 TODO —— 但本项目（macOS 本地开发）下会通过。

- [ ] **Step 8: 提交**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): add isImageIndexed with request/remote dispatch + factory predicate"
```

---

### 任务 4: 在 engine 上加 `mainExecutablePath` 与 `loadImageForBackgroundIndexing`（带 `request/remote` 分发）

**文件:**
- 修改: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift`
- 修改: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`（增加两个 `CommandNames` case + 处理器）
- 修改: `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DyldUtilities.swift`（仅当辅助缺失时）
- 测试: 追加到 `RuntimeEngineIndexStateTests.swift`

**为什么要 `request/remote`:** 与任务 3 相同的理由。`mainExecutablePath` 必须反映目标进程，而非本地进程；对于远程源，正确答案只能在服务端获得。`loadImageForBackgroundIndexing` 也必须在目标进程内执行。

- [ ] **Step 1: 探索 `DyldUtilities` 与 `MachOImage` 中查询主可执行文件的 API**

```bash
rg -n "_dyld_get_image_name|_dyld_get_image_header|mainExecutable|static func images|MachOImage\.current" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/ /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/MachOKit/Sources/MachOKit/ --type swift | head
```

记录规范的调用序列。在 macOS 上主可执行文件是 dyld 索引 0 的镜像；常见模式是 `String(cString: _dyld_get_image_name(0))`。

- [ ] **Step 2: 追加失败测试**

在 `RuntimeEngineIndexStateTests.swift` 中追加：

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

- [ ] **Step 3: 增加 `CommandNames` case + 服务端处理器**

在 `RuntimeEngine.swift` 的 `CommandNames` 枚举：

```swift
case mainExecutablePath
case loadImageForBackgroundIndexing
```

在 `setMessageHandlerBinding(...)` 块中：

```swift
setMessageHandlerBinding(forName: .mainExecutablePath,
                         of: self) { $0.mainExecutablePath }
setMessageHandlerBinding(forName: .loadImageForBackgroundIndexing,
                         of: self) { $0.loadImageForBackgroundIndexing(at:) }
```

- [ ] **Step 4: 用 `request/remote` 分发实现新的 engine 方法**

追加到 `RuntimeEngine+BackgroundIndexing.swift`:

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

注意两次 factory 调用的 `try await` —— 与已核验的签名 `section(for:progressContinuation:) async throws -> (isExisted: Bool, section: ...)` 一致（`RuntimeObjCSection.swift:704` / `RuntimeSwiftSection.swift:802`）。

- [ ] **Step 5: 运行测试 —— 预期通过**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeEngineIndexStateTests 2>&1 | xcsift
```

预期：该文件中的所有测试通过。

- [ ] **Step 6: 提交**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): mainExecutablePath + loadImageForBackgroundIndexing with request/remote"
```

---

### 任务 4.5: 在 `RuntimeEngine` 上添加 `imageDidLoadPublisher`

**文件:**
- 修改: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`
- 测试: 追加到 `RuntimeEngineIndexStateTests.swift`

**为什么:** Coordinator（任务 16）需要一个携带新加载镜像路径的信号。当今 `RuntimeEngine` 只暴露 `reloadDataPublisher`（无负载）和 `imageNodesPublisher`（完整列表）；没有按镜像的信号。任务 16 会订阅这一新 publisher。本地分支在 `loadImage(at:)` 成功后发出；远程分支的 `setMessageHandlerBinding(forName: .imageDidLoad)` 处理器在服务器转发事件时由客户端发出。

- [ ] **Step 1: 检查现有的 `reloadDataPublisher` 接线，作为模式参照**

```bash
rg -n "reloadDataPublisher|reloadDataSubject|PassthroughSubject" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift | head
```

预期发现：`private nonisolated let reloadDataSubject = PassthroughSubject<Void, Never>()`、暴露它的 `nonisolated` 公共属性，以及在服务端处理器表上的 `setMessageHandlerBinding(forName: .reloadData) { $0.reloadDataSubject.send() }`。

- [ ] **Step 2: 添加 subject + publisher**

在 `RuntimeEngine.swift` 中已有的 `reloadDataSubject` 旁：

```swift
private nonisolated let imageDidLoadSubject = PassthroughSubject<String, Never>()

public nonisolated var imageDidLoadPublisher: some Publisher<String, Never> {
    imageDidLoadSubject.eraseToAnyPublisher()
}
```

- [ ] **Step 3: 在 `CommandNames` 加 `.imageDidLoad` 并双向接线**

在 `CommandNames`:

```swift
case imageDidLoad
```

在处理器表中，与 `reloadData` 模式镜像，让远程客户端也接收事件：

```swift
setMessageHandlerBinding(forName: .imageDidLoad) { (engine: RuntimeEngine, path: String) in
    engine.imageDidLoadSubject.send(path)
}
```

在 `loadImage(at:)`（当前位于 `RuntimeEngine.swift:485-495`）中，在已有的 `reloadData(isReloadImageNodes: false)` 调用之后发出：

```swift
imageDidLoadSubject.send(path)
sendRemoteDataIfNeeded(name: .imageDidLoad, payload: path)
// or inline the remote push similar to sendRemoteDataIfNeeded(isReloadImageNodes:)
```

核验现有 `sendRemoteDataIfNeeded(...)` 签名 —— 如果它不接受任意命令名，在它旁边新增一个小辅助 `sendRemoteImageDidLoad(_ path: String)`。

- [ ] **Step 4: 追加测试**

```swift
    func test_imageDidLoadPublisher_firesAfterLoadImage() async throws {
        let engine = await RuntimeEngine(source: .local)
        let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
        let expectation = expectation(description: "imageDidLoad")
        var received: String?
        // imageDidLoadPublisher is `nonisolated` — no await needed; Swift 6
        // would warn "no 'async' operations occur in 'await' expression".
        let cancellable = engine.imageDidLoadPublisher.sink { path in
            received = path
            expectation.fulfill()
        }
        try await engine.loadImage(at: foundation)
        await fulfillment(of: [expectation], timeout: 5)
        cancellable.cancel()
        XCTAssertEqual(received, foundation)
    }
```

如果测试文件顶部尚无 `import Combine`，请添加。

- [ ] **Step 5: 运行测试**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeEngineIndexStateTests 2>&1 | xcsift
```

- [ ] **Step 6: 提交**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): imageDidLoadPublisher for per-path load notifications"
```

---

## Phase 3 —— 索引管理器

### 任务 5: 声明 engine 表示协议与 mock

**文件:**
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/BackgroundIndexingEngineRepresenting.swift`
- 创建: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/MockBackgroundIndexingEngine.swift`

- [ ] **Step 1: 创建协议**

文件 `BackgroundIndexingEngineRepresenting.swift`:

```swift
/// Abstraction seam for `RuntimeBackgroundIndexingManager` to interact with a
/// `RuntimeEngine`. Lets tests swap in a fake engine without real dyld I/O.
///
/// Methods that proxy to remote sources via `RuntimeEngine.request { ... } remote: { ... }`
/// are `async throws` because the XPC / TCP transport can fail. Pure-local
/// queries (`canOpenImage`) stay non-throwing.
///
/// Note: the protocol intentionally does NOT expose `MachOImage` —— that type
/// is a non-Sendable struct (contains unsafe pointers); returning it across
/// actor boundaries triggers Swift 6 strict-concurrency errors. Callers that
/// only need to gate recursion can use `canOpenImage(at:)` instead.
///
/// Conformance is `Sendable` only —— no `AnyObject` constraint. The manager
/// holds the engine by value (`engine: any BackgroundIndexingEngineRepresenting`),
/// no `weak`/`unowned` is needed, and `actor RuntimeEngine`'s conformance
/// would otherwise depend on the Swift 5.7+ "actor satisfies AnyObject" edge
/// behavior unnecessarily.
protocol BackgroundIndexingEngineRepresenting: Sendable {
    func isImageIndexed(path: String) async throws -> Bool
    func loadImageForBackgroundIndexing(at path: String) async throws
    func mainExecutablePath() async throws -> String
    /// Whether the image at `path` can be opened as a MachO. Pure local check.
    func canOpenImage(at path: String) async -> Bool
    /// Returns the LC_RPATH entries for the image at `path`. Empty when the
    /// image cannot be opened.
    func rpaths(for path: String) async throws -> [String]
    /// Returns the resolved dependency dylib paths for the image at `path`,
    /// excluding lazy-load entries. May return nil `resolvedPath` entries for
    /// unresolved install names; the caller marks them failed.
    func dependencies(for path: String)
        async throws -> [(installName: String, resolvedPath: String?)]
}
```

- [ ] **Step 2: 让 `RuntimeEngine` 遵循该协议**

追加到 `RuntimeEngine+BackgroundIndexing.swift`。`MachOImage(name:)` 仅在 actor-isolated 实现内部使用，**不**作为协议返回值跨边界传递：

```swift
import MachOKit

extension RuntimeEngine: BackgroundIndexingEngineRepresenting {
    func canOpenImage(at path: String) -> Bool {
        MachOImage(name: path) != nil
    }

    func rpaths(for path: String) -> [String] {
        guard let image = MachOImage(name: path) else { return [] }
        return image.rpaths   // confirmed: MachOImage.swift:145 returns [String]
    }

    func dependencies(for path: String) async throws
        -> [(installName: String, resolvedPath: String?)]
    {
        guard let image = MachOImage(name: path) else { return [] }
        let resolver = DylibPathResolver()
        let main = try await mainExecutablePath()
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

注：`canOpenImage` 与 `rpaths` 的 conformance 实现保留为 non-throwing，Swift 允许 sync / non-throwing 函数满足 `async throws` 协议要求。`dependencies` 必须是 `async throws`，因为它内部 `try await mainExecutablePath()`（远端分发可能抛错）。`MachOImage` 类型自身不出现在协议表面 —— 它是非 Sendable 的结构体，仅在 actor-isolated 实现内部使用。

- [ ] **Step 3: 创建 mock**

文件 `MockBackgroundIndexingEngine.swift`:

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

    func canOpenImage(at path: String) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths[path] != nil
    }
    func rpaths(for path: String) async -> [String] { [] }
    func dependencies(for path: String)
        async -> [(installName: String, resolvedPath: String?)]
    {
        lock.lock(); defer { lock.unlock() }
        return paths[path]?.dependencies ?? []
    }
}
```

注：mock 的所有方法保留为 non-throwing 形式（`async -> ...` 而非 `async throws -> ...`）—— Swift 允许更弱的实现满足更强的协议要求。这样测试代码内调用 mock 时仍需 `try await`（因为通过 protocol 调用），但 mock 内部不必显式 throw。`MachOImage` 不再出现在 mock 的接口或导入中。

- [ ] **Step 4: 编译检查**

```bash
cd RuntimeViewerCore && swift build 2>&1 | xcsift
```

预期：构建成功。

- [ ] **Step 5: 提交**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): protocol and mock engine for background indexing"
```

---

### 任务 6: 创建带 AsyncStream 的 manager actor 骨架

**文件:**
- 创建: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift`
- 测试: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: 写出针对空 manager 状态的失败测试**

文件 `RuntimeBackgroundIndexingManagerTests.swift`:

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

- [ ] **Step 2: 运行测试 —— 预期编译失败**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

预期：`RuntimeBackgroundIndexingManager` 未定义。

- [ ] **Step 3: 实现骨架**

文件 `RuntimeBackgroundIndexingManager.swift`:

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

    // Placeholder — Task 7 replaces with real BFS.
    func expandDependencyGraph(rootPath: String, depth: Int)
        async -> [RuntimeIndexingTaskItem]
    {
        if (try? await engine.isImageIndexed(path: rootPath)) == true { return [] }
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

- [ ] **Step 4: 运行测试 —— 预期通过**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

预期：两个测试通过。

- [ ] **Step 5: 提交**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): manager actor skeleton with AsyncStream plumbing"
```

---

### 任务 7: 实现 `expandDependencyGraph` —— 带深度限制与短路的 BFS

**文件:**
- 修改: `RuntimeBackgroundIndexingManager.swift`
- 测试: 追加到 `RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: 写出失败测试**

追加到 `RuntimeBackgroundIndexingManagerTests.swift`:

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

- [ ] **Step 2: 替换占位 `expandDependencyGraph` 实现**

在 `RuntimeBackgroundIndexingManager.swift` 中将已有的 stub 替换为：

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

        // `try?` — if the engine errors out (e.g. remote XPC drops mid-batch),
        // treat the image as unindexed; loadImageForBackgroundIndexing will
        // surface a real failure later. This matches Evolution 0002 Alt D:
        // failure ≠ indexed.
        if (try? await engine.isImageIndexed(path: path)) == true { continue }

        // Non-root paths that can't be opened as MachO go straight to
        // `.failed` and don't recurse — saves a wasted dlopen attempt later.
        // Root is always represented so that the batch has at least one item.
        if path != rootPath && !(await engine.canOpenImage(at: path)) {
            items.append(.init(id: path, resolvedPath: path,
                               state: .failed(message: "cannot open MachOImage"),
                               hasPriorityBoost: false))
            continue
        }

        items.append(.init(id: path, resolvedPath: path,
                           state: .pending, hasPriorityBoost: false))
        guard level < depth else { continue }

        // `try?` — if dependency lookup fails, treat as no deps; the path
        // itself is still pending and will be retried on next batch.
        let deps = (try? await engine.dependencies(for: path)) ?? []
        for dep in deps {
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

- [ ] **Step 3: 运行测试 —— 预期通过**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

预期：该文件中所有测试，包括新增的，均通过。

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): implement dependency graph BFS for background indexing"
```

---

### 任务 8: 用 AsyncSemaphore 实现并发批次执行

**文件:**
- 修改: `RuntimeBackgroundIndexingManager.swift`
- 测试: 追加到 `RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: 写出失败测试**

追加：

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
        func isImageIndexed(path: String) async throws -> Bool {
            try await base.isImageIndexed(path: path)
        }
        func loadImageForBackgroundIndexing(at path: String) async throws {
            counter.enter()
            defer { counter.exit() }
            try await Task.sleep(nanoseconds: 20_000_000)
            try await base.loadImageForBackgroundIndexing(at: path)
        }
        func mainExecutablePath() async throws -> String {
            try await base.mainExecutablePath()
        }
        func canOpenImage(at path: String) async -> Bool {
            await base.canOpenImage(at: path)
        }
        func rpaths(for path: String) async throws -> [String] {
            try await base.rpaths(for: path)
        }
        func dependencies(for path: String)
            async throws -> [(installName: String, resolvedPath: String?)]
        {
            try await base.dependencies(for: path)
        }
    }
```

- [ ] **Step 2: 用真正的执行替换 `runBatch` 桩**

在 `RuntimeBackgroundIndexingManager.swift` 中替换 `runBatch` 并引入辅助 `runSingleIndex`:

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

- [ ] **Step 3: 运行测试 —— 预期通过**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

预期：之前的所有测试加上 3 个新增测试通过。

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): concurrent batch execution with AsyncSemaphore"
```

---

### 任务 9: 实现 `cancelBatch` 与 `cancelAllBatches`

**文件:**
- 修改: `RuntimeBackgroundIndexingManager.swift`
- 测试: 追加到 `RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: 写出失败测试**

追加：

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

- [ ] **Step 2: 实现取消**

在 `RuntimeBackgroundIndexingManager` 中加入：

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

更新 `finalize` 以传播已经设置的 `isCancelled` 标志：

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

- [ ] **Step 3: 运行测试 —— 预期通过**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): cancelBatch and cancelAllBatches on indexing manager"
```

---

### 任务 10: 实现 `prioritize(imagePath:)`

**文件:**
- 修改: `RuntimeBackgroundIndexingManager.swift`
- 测试: 追加到 `RuntimeBackgroundIndexingManagerTests.swift`

- [ ] **Step 1: 写出失败测试**

追加：

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

- [ ] **Step 2: 实现 prioritize**

在 `RuntimeBackgroundIndexingManager` 中加入：

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

- [ ] **Step 3: 运行测试 —— 预期通过**

```bash
cd RuntimeViewerCore && swift test --filter RuntimeBackgroundIndexingManagerTests 2>&1 | xcsift
```

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerCore
git commit -m "feat(core): prioritize pending item to head of queue"
```

---

## Phase 4 —— Engine 集成

### 任务 11: 在 `RuntimeEngine` 上持有 `RuntimeBackgroundIndexingManager`

**文件:**
- 修改: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`（init 区域和新增存储属性）

- [ ] **Step 1: 检查 RuntimeEngine init**

```bash
rg -n "init\(source|actor RuntimeEngine" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift | head
```

记录初始化器签名，以便在不破坏调用方的前提下注入 manager。

- [ ] **Step 2: 增加显式存储属性，并在 `init` 末尾初始化**

actor 上的 `lazy var` 强制每次首次访问都通过 actor 隔离，初始化时机变得不直观，且与 `nonisolated` 属性访问器交互不顺畅。改用一个显式的隐式可解包存储属性，作为 `init` 的最后一行赋值：

```swift
// Near the other stored properties:
public private(set) var backgroundIndexingManager: RuntimeBackgroundIndexingManager!

// Last line of init(source:...):
self.backgroundIndexingManager = RuntimeBackgroundIndexingManager(engine: self)
```

为什么 IUO 而不是普通 `let`：`RuntimeEngine.init` 末尾把 `self` 交给 `RuntimeBackgroundIndexingManager(engine: self)` 时，所有其他 stored property 已经初始化完成（参见 `RuntimeEngine.swift:178-179`），因此不存在"前向引用 self"问题。真正需要 IUO 的原因是更纯粹的初始化时机偏好：把 manager 的构造放在 `init` 末尾、所有其它依赖到位之后，是最易读的写法；普通 `let` 要求在声明时给初值，把构造表达式上提到 stored-property 区域反而割裂了"engine 完成 → 构造 manager"这条线性叙事。manager 在 init 之后只读，不存在重新赋值或 nil 访问路径，IUO 的不安全面在此被结构性地约束住。

- [ ] **Step 3: 构建**

```bash
cd RuntimeViewerCore && swift build 2>&1 | xcsift
```

预期：构建无报错。

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
git commit -m "feat(core): expose backgroundIndexingManager on RuntimeEngine"
```

---

## Phase 5 —— Settings

### 任务 12: 在 `Settings+Types.swift` 中加入 `BackgroundIndexing` 结构体

**文件:**
- 修改: `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift`

- [ ] **Step 1: 阅读已有的 MCP 结构体以匹配风格**

```bash
rg -n "public struct MCP|public struct Notifications|public var mcp" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift
```

- [ ] **Step 2: 追加新结构体与根属性**

在 `Settings+Types.swift` 中、其他嵌套设置结构体旁，加入：

```swift
@Codable @MemberInit public struct BackgroundIndexing {
    @Default(false) public var isEnabled: Bool
    @Default(1)     public var depth: Int
    @Default(4)     public var maxConcurrency: Int
    public static let `default` = Self()
}
```

在根 `Settings` 类中、紧挨 `mcp` 加入新存储属性。**必须**镜像现有字段的 `didSet { scheduleAutoSave() }` 模式（见 `Settings.swift:14-37` 中 `general` / `notifications` / `transformer` / `mcp` / `update` 全部使用这一形式），否则 toggle / depth / maxConcurrency 改动不会自动写盘：

```swift
@Default(BackgroundIndexing.default)
public var backgroundIndexing: BackgroundIndexing = .init() {
    didSet { scheduleAutoSave() }
}
```

- [ ] **Step 3: 构建 packages**

```bash
cd RuntimeViewerPackages && swift package update && swift build 2>&1 | xcsift
```

预期：构建无报错。

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift
git commit -m "feat(settings): add BackgroundIndexing settings struct"
```

---

### 任务 13: 添加 Settings UI 页面

**文件:**
- 修改: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift`
- 创建: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/BackgroundIndexingSettingsView.swift`

- [ ] **Step 1: 阅读已有 Settings 根视图**

```bash
rg -n "case general|case mcp|SettingsPage|contentView" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift | head -20
```

- [ ] **Step 2: 增加枚举 case 和 content switch 分支**

在 `SettingsRootView.swift` 中给 `SettingsPage` 枚举添加 `case backgroundIndexing`，匹配现有 case 的格式。

提供标题与图标：

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

在 `contentView` switch 中加入：

```swift
case .backgroundIndexing: BackgroundIndexingSettingsView()
```

- [ ] **Step 3: 创建 SwiftUI 页面**

文件 `BackgroundIndexingSettingsView.swift`:

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

- [ ] **Step 4: 构建**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 5: 提交**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI
git commit -m "feat(settings-ui): Background Indexing settings page"
```

---

## Phase 6 —— Coordinator (RuntimeViewerApplication)

### 任务 14: 创建 `RuntimeBackgroundIndexingCoordinator` 骨架

**文件:**
- 创建: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift`

- [ ] **Step 1: 阅读 DocumentState 以了解 coordinator 将存活的环境**

```bash
rg -n "final class DocumentState|runtimeEngine|public var" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift | head -30
```

记录引擎属性的名称（很可能是 `runtimeEngine`），以及 `DocumentState` 是否已经为 `loadImage` 完成暴露了一个可观察对象（如 Rx subject） —— 这决定了任务 15 中的订阅接线方式。

- [ ] **Step 2: 创建 coordinator 骨架**

文件 `RuntimeBackgroundIndexingCoordinator.swift`:

```swift
import Foundation
import RuntimeViewerCore
import RuntimeViewerSettings
import RxSwift
import RxRelay

@MainActor
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
        // The class is `@MainActor`, so this Task and its `for await` loop
        // run on the main actor. `apply(event:)` can be called synchronously
        // without an extra `MainActor.run` hop.
        eventPumpTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.engine.backgroundIndexingManager.events
            for await event in stream {
                self.apply(event: event)
            }
        }
    }

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

`mutating(_:_:)` 辅助函数现在是 coordinator 上的私有方法（参见上面插入位置）。它不是全局函数 —— 文件作用域的 `private` 仍会污染同模块未来文件，而私有方法把工具范围限定在需要它的 coordinator 内。

- [ ] **Step 3: 构建**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing
git commit -m "feat(application): coordinator skeleton for background indexing"
```

---

### 任务 15: 把 coordinator 接入 document 生命周期 —— 启动 `.appLaunch` 批次

**文件:**
- 修改: `RuntimeBackgroundIndexingCoordinator.swift`

- [ ] **Step 1: 增加 settings 访问与启动入口**

追加到 `RuntimeBackgroundIndexingCoordinator.swift`:

```swift
extension RuntimeBackgroundIndexingCoordinator {
    public func documentDidOpen() {
        // The class is `@MainActor`, so this Task inherits main-actor isolation
        // and can mutate `documentBatchIDs` synchronously after the awaits.
        Task { [weak self] in
            guard let self else { return }
            let settings = self.currentBackgroundIndexingSettings()
            guard settings.isEnabled else { return }
            // mainExecutablePath is `async throws` because remote (XPC / TCP)
            // sources may fail; on launch we silently skip the batch in that
            // case rather than surface the error to the user.
            guard let root = try? await engine.mainExecutablePath(),
                  !root.isEmpty else { return }
            let id = await engine.backgroundIndexingManager.startBatch(
                rootImagePath: root,
                depth: settings.depth,
                maxConcurrency: settings.maxConcurrency,
                reason: .appLaunch)
            self.documentBatchIDs.insert(id)
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

    private func currentBackgroundIndexingSettings() -> BackgroundIndexing {
        // Access the Settings snapshot via the project's existing mechanism.
        // If `Settings.shared` is the accessor, use it; adjust to match.
        Settings.shared.backgroundIndexing
    }
}
```

检查 Settings 单例的访问模式；`Settings.shared.backgroundIndexing` 只是占位 —— 用代码库实际使用的方式替换（如 `@Dependency(\.settings)`）。

- [ ] **Step 2: 构建**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 3: 提交**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
git commit -m "feat(application): documentDidOpen / documentWillClose hooks for indexing"
```

---

### 任务 16: 订阅镜像加载事件 —— 启动按镜像的依赖批次

**文件:**
- 修改: `RuntimeBackgroundIndexingCoordinator.swift`

**为什么用 Combine `.values` 桥到 AsyncStream:** 任务 4.5 引入的 `imageDidLoadPublisher` 是 `some Publisher<String, Never>`（Combine）。Coordinator 已经用 `Task { for await event in stream }` 模式消费 manager 的 `AsyncStream`（任务 14 `startEventPump`），把 publisher 桥到 async-for-loop 复用同一模式，比再起一条 RxCombine bridge 简单。

- [ ] **Step 1: 添加按 path 的事件泵存储**

在 coordinator 类内、与 `eventPumpTask` 并列：

```swift
private var imageLoadedPumpTask: Task<Void, Never>?
```

更新 `deinit` 一并取消：

```swift
deinit {
    eventPumpTask?.cancel()
    imageLoadedPumpTask?.cancel()
}
```

- [ ] **Step 2: 在 coordinator init 的 `startEventPump()` 之后增加订阅**

```swift
private func startImageLoadedPump() {
    // Class is `@MainActor`; this Task and `for await` loop run on the main
    // actor. `handleImageLoaded` doesn't need a `MainActor.run` hop.
    imageLoadedPumpTask = Task { [weak self] in
        guard let self else { return }
        // Combine.Publisher.values bridges to AsyncSequence on macOS 12+ /
        // iOS 15+; the project's deployment targets satisfy this. Errors are
        // Never on this publisher, so no try is needed.
        for await path in self.engine.imageDidLoadPublisher.values {
            await self.handleImageLoaded(path: path)
        }
    }
}

private func handleImageLoaded(path: String) async {
    let settings = currentBackgroundIndexingSettings()
    guard settings.isEnabled else { return }
    // Avoid double-starting if the path is the main executable being opened
    // at app launch — documentDidOpen already dispatched that batch. Manager
    // dedups batches that share rootImagePath + reason discriminant, so a
    // second call here is a no-op rather than a wasted batch.
    let id = await engine.backgroundIndexingManager.startBatch(
        rootImagePath: path,
        depth: settings.depth,
        maxConcurrency: settings.maxConcurrency,
        reason: .imageLoaded(path: path))
    self.documentBatchIDs.insert(id)
}
```

在 `init` 末尾、`startEventPump()` 之后调用 `startImageLoadedPump()`。

- [ ] **Step 3: 构建**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
git commit -m "feat(application): subscribe to engine image-loaded events to spawn batches"
```

---

### 任务 17: 通过 `withObservationTracking` 响应 Settings 变更

**文件:**
- 修改: `RuntimeBackgroundIndexingCoordinator.swift`

**为什么用 `withObservationTracking`（不用 Combine）:** `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift:6` 的 `Settings` 声明为 `@Observable`。它没有 Combine publisher，`scheduleAutoSave` 路径只通过 `didSet` 触发。增加平行的 `PassthroughSubject<Settings, Never>` 会复制事实来源。`withObservationTracking` 是原生匹配 —— coordinator 在 `apply` 闭包内读取被跟踪的属性，Swift Observation 注册一次性观察者。我们在 `onChange` 内重新注册以在每次变更后保持观察。

- [ ] **Step 1: 添加 observation 导入与状态**

在 `RuntimeBackgroundIndexingCoordinator.swift` 顶部：

```swift
import Observation
import RuntimeViewerSettings
```

在 coordinator 类上加私有状态：

```swift
private var lastKnownIsEnabled: Bool = false
```

- [ ] **Step 2: 实现 observation 循环**

类已是 `@MainActor`,所有方法默认在主线程运行,不必再单独标 `@MainActor`。

```swift
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

- [ ] **Step 3: 在 init 中播种初始状态并注册**

类是 `@MainActor`,init 也在主线程,直接同步播种与订阅:

```swift
// At end of init(documentState:)
self.lastKnownIsEnabled = Settings.shared.backgroundIndexing.isEnabled
self.subscribeToSettings()
```

- [ ] **Step 4: 构建**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 5: 提交**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
git commit -m "feat(application): observe Settings.backgroundIndexing via withObservationTracking"
```

---

## Phase 7 —— Toolbar 弹出框 UI

### 任务 18: 创建 `BackgroundIndexingNode` 与弹出框 ViewModel（在 `MainRoute` 上）

**文件:**
- 创建: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingNode.swift`
- 创建: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewModel.swift`

**为什么没有单独的 Route:** `MainCoordinator` 声明为 `final class MainCoordinator: SceneCoordinator<MainRoute, MainTransition>`（`MainCoordinator.swift:11`）。它的 `Route` 已经绑定到 `MainRoute`；为 `BackgroundIndexingPopoverRoute` 增加第二个、有条件的 `Router` conformance 无法编译。改为给 `MainRoute` 加一个 case（任务 21），让 ViewModel 是 `ViewModel<MainRoute>`。

- [ ] **Step 1: 创建 `BackgroundIndexingNode`**

```swift
import RuntimeViewerCore

enum BackgroundIndexingNode: Hashable {
    case batch(RuntimeIndexingBatch)
    case item(batchID: RuntimeIndexingBatchID, item: RuntimeIndexingTaskItem)
}
```

- [ ] **Step 2: 在 `MainRoute` 上创建 ViewModel**

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
    @Observed private(set) var hasAnyFailure: Bool = false
    @Observed private(set) var subtitle: String = ""

    private let coordinator: RuntimeBackgroundIndexingCoordinator
    private let openSettingsRelay = PublishRelay<Void>()

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
        let hasAnyFailure: Driver<Bool>
        let subtitle: Driver<String>
        // Forwarded to the ViewController so it can call
        // `SettingsWindowController.shared.showWindow(nil)` directly —— mirrors
        // MCPStatusPopoverViewController.swift:200-203 (no `MainRoute` case
        // exists for openSettings).
        let openSettings: Signal<Void>
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
            .asDriver(onErrorDriveWith: .empty())
            .driveOnNext { [weak self] state in
                guard let self else { return }
                subtitle = Self.subtitleFor(state)
                hasAnyFailure = state.hasAnyFailure
            }
            .disposed(by: rx.disposeBag)

        // ViewModel base class (`open class ViewModel<Route: Routable>`) is
        // `@MainActor`, so `transform` runs on the main actor and can call
        // `subscribeToIsEnabled()` synchronously. Synchronous seed is what
        // keeps the popover's first frame from flashing the "disabled"
        // empty state when Settings is actually enabled.
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

        // Forward the user signal to the output. The ViewController will
        // open the Settings window directly — see MCPStatusPopover precedent.
        input.openSettings.emitOnNext { [weak self] in
            guard let self else { return }
            openSettingsRelay.accept(())
        }.disposed(by: rx.disposeBag)

        return Output(
            nodes: $nodes.asDriver(),
            isEnabled: $isEnabled.asDriver(),
            hasAnyBatch: $hasAnyBatch.asDriver(),
            hasAnyFailure: $hasAnyFailure.asDriver(),
            subtitle: $subtitle.asDriver(),
            openSettings: openSettingsRelay.asSignal()
        )
    }

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

注意：`coordinator.clearFailedBatches()` 在任务 24 与"保留失败批次直至被清除"的 reducer 变更一起加入。如果你在任务 24 之前到达任务 18，把 `clearFailed` 绑定保留为 TODO 直通，回头再补。

- [ ] **Step 3: 把两个新文件加入 Xcode 项目**

使用 xcodeproj MCP，加入：

```
RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingNode.swift
RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewModel.swift
```

均加入 `RuntimeViewerUsingAppKit` target。**不存在** `BackgroundIndexingPopoverRoute.swift` —— 路由通过 `MainRoute`。

- [ ] **Step 4: 构建 app target**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

预期：构建无报错。

- [ ] **Step 5: 提交**

```bash
git add RuntimeViewerUsingAppKit
git commit -m "feat(ui): popover ViewModel on MainRoute + BackgroundIndexingNode"
```

---

### 任务 19: 构建弹出框 ViewController

**文件:**
- 创建: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift`

- [ ] **Step 1: 创建 ViewController**

```swift
import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettingsUI    // SettingsWindowController.shared
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
    private let clearFailedRelay = PublishRelay<Void>()
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
    private let clearFailedButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Clear Failed"
        $0.isHidden = true   // shown only when a retained failed batch exists
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
            clearFailedButton
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
        clearFailedButton.target = self
        clearFailedButton.action = #selector(clearFailedClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsClicked)
    }

    @objc private func cancelAllClicked() { cancelAllRelay.accept(()) }
    @objc private func clearFailedClicked() { clearFailedRelay.accept(()) }
    @objc private func closeClicked() { dismiss(nil) }
    @objc private func openSettingsClicked() { openSettingsRelay.accept(()) }

    override func setupBindings(for viewModel: BackgroundIndexingPopoverViewModel) {
        super.setupBindings(for: viewModel)
        let input = BackgroundIndexingPopoverViewModel.Input(
            cancelBatch: cancelBatchRelay.asSignal(),
            cancelAll: cancelAllRelay.asSignal(),
            clearFailed: clearFailedRelay.asSignal(),
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

        output.hasAnyFailure
            .driveOnNext { [weak self] hasFailure in
                guard let self else { return }
                clearFailedButton.isHidden = !hasFailure
            }
            .disposed(by: rx.disposeBag)

        // Direct-call into the Settings window. There is no `MainRoute.openSettings`
        // case — see MCPStatusPopoverViewController.swift:200-203 for the same pattern.
        output.openSettings.emitOnNext {
            SettingsWindowController.shared.showWindow(nil)
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

- [ ] **Step 2: 加入 Xcode 项目**

xcodeproj MCP `add_file`：将 `BackgroundIndexingPopoverViewController.swift` 加入 `RuntimeViewerUsingAppKit` target。

- [ ] **Step 3: 构建**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerUsingAppKit
git commit -m "feat(ui): popover view controller for background indexing"
```

---

### 任务 20: 构建带 `NSProgressIndicator` 叠加的 Toolbar item view

**文件:**
- 创建: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingToolbarItemView.swift`
- 创建: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingToolbarItem.swift`

- [ ] **Step 1: 创建自定义 view**

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

- [ ] **Step 2: 创建 `NSToolbarItem` 子类**

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

- [ ] **Step 3: 把两个文件都加入 Xcode**

xcodeproj MCP `add_file` 两次，均加入 `RuntimeViewerUsingAppKit` target。

- [ ] **Step 4: 构建**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 5: 提交**

```bash
git add RuntimeViewerUsingAppKit
git commit -m "feat(ui): toolbar item view and item class for background indexing"
```

---

### 任务 21: 注册 toolbar item 并增加 `MainRoute.backgroundIndexing` case

**文件:**
- 修改: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainRoute.swift`
- 修改: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift`
- 修改: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift`

**为什么是一个 route case 而不是单独的 `Router` conformance:** `MainCoordinator` 已是 `SceneCoordinator<MainRoute, MainTransition>`。一个有条件的 `extension MainCoordinator: Router where Route == BackgroundIndexingPopoverRoute` 无法编译 —— `Route` 已固定到 `MainRoute`。因此本计划直接在 `MainRoute` 上扩展一个 case，并把弹出框的 `.openSettings` 通过已有的 `MainRoute.openSettings` case 路由。

- [ ] **Step 1: 检查现有的 MCPStatus 接线**

```bash
rg -n "mcpStatus|MCPStatusToolbarItem|toolbarDefaultItemIdentifiers|itemForItemIdentifier" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift | head -30
```

也查看 `MainRoute.swift:18` —— 已有 case 字面量是 `case mcpStatus(sender: NSView)`，而非 `mcpStatusPopover`。匹配该命名风格。

- [ ] **Step 2: 在 `MainRoute` 上添加 route case**

在 `MainRoute.swift` 中、紧挨 `case mcpStatus(sender: NSView)` 加入：

```swift
case backgroundIndexing(sender: NSView)
```

（无 `Popover` 后缀 —— 与同级 `mcpStatus` 先例一致。）

- [ ] **Step 3: 在 `MainToolbarController` 中注册 toolbar item**

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

精确字段名（`documentState`、`mainCoordinator`）必须匹配 `MainToolbarController` 已有字段 —— 如果属性拼写不同请相应调整。

- [ ] **Step 4: 在 `MainCoordinator.prepareTransition` 处理新 case**

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

不需要 `extension MainCoordinator: Router where Route == ...` 包装 —— `self` 已经是 `Router<MainRoute>`,作为 ViewModel 的 router 注入即可。弹出框的 `Open Settings` 按钮**不**经 router:`MainRoute` 没有 `openSettings` case;ViewController 在 `setupBindings` 中订阅 `output.openSettings` 直接调用 `SettingsWindowController.shared.showWindow(nil)`(与 `MCPStatusPopoverViewController` 完全相同的处理方式)。

- [ ] **Step 5: 构建**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 6: 提交**

```bash
git add RuntimeViewerUsingAppKit
git commit -m "feat(ui): toolbar item + MainRoute.backgroundIndexing popover route"
```

---

## Phase 8 —— 集成与 QA

### 任务 22: 在 `DocumentState` 上持有 coordinator，并调用生命周期钩子

**文件:**
- 修改: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift`
- 修改: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift`

- [ ] **Step 1: 给 `DocumentState` 添加 coordinator 属性并强化 `runtimeEngine` 不变量**

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

编辑 `DocumentState.swift:10-11` 处 `runtimeEngine` 的现有声明，加入上面的 doc comment；保留类型与初值不变。

- [ ] **Step 2: 在 `Document` 中调用生命周期钩子**

在 `Document.swift`:

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

编辑前先检查现有的 `makeWindowControllers` / `close` 实现；插入这些行而不删除现有逻辑。

- [ ] **Step 3: 构建（package + app）**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 4: 提交**

```bash
git add RuntimeViewerPackages RuntimeViewerUsingAppKit
git commit -m "feat(app): wire background indexing coordinator into Document lifecycle"
```

---

### 任务 23: 把 sidebar 选中接到 `prioritize`

**文件:**
- 修改: 观察 sidebar 选中的 coordinator 或 VC（很可能是 `MainCoordinator` 或 `SidebarCoordinator`）

- [ ] **Step 1: 找到 sidebar 镜像选中信号**

```bash
rg -n "imageSelected|didSelectImage|sidebar.*Selected" /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/ /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/ | head -20
```

记录精确的信号名称及其发布位置。

- [ ] **Step 2: 在 sidebar coordinator init（或处理选中的位置）中加入：**

```swift
sidebarViewModel.$selectedImagePath
    .driveOnNext { [weak self] path in
        guard let self, let path else { return }
        documentState.backgroundIndexingCoordinator.prioritize(imagePath: path)
    }
    .disposed(by: rx.disposeBag)
```

使用任何已经跟踪 sidebar 镜像选中的 observable。如果没有，把已有 relay 提升为 `public` 并使用。

- [ ] **Step 3: 构建**

```bash
xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 4: 提交**

```bash
git add .
git commit -m "feat(app): prioritize indexing when user selects an image in sidebar"
```

---

### 任务 24: 保留失败批次；每个批次结束时刷新一次镜像列表

**文件:**
- 修改: `RuntimeBackgroundIndexingCoordinator.swift`

**为什么保留失败批次:** Toolbar 状态 `.hasFailures(...)` 由 coordinator 的 `aggregateState` 派生。如果 `.batchFinished` 立即移除批次 —— 即便包含 `.failed` 项 —— toolbar 永远不会浮现失败。本任务修改 `.batchFinished` / `.batchCancelled` reducer：干净完成与取消会移除；含任意 `.failed` 项的完成保留在 `batchesRelay` 中，直到用户从弹出框调用 `clearFailedBatches()`。

- [ ] **Step 1: 更新 `apply(event:)` reducer 中的 `.batchFinished` / `.batchCancelled`**

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

- [ ] **Step 2: 在 coordinator 公共表面加入 `clearFailedBatches()`**

```swift
public func clearFailedBatches() {
    // Class is `@MainActor`; we're already on the main thread when called
    // from the popover's button. No hop required.
    let remaining = batchesRelay.value.filter { batch in
        !batch.items.contains { if case .failed = $0.state { true } else { false } }
    }
    batchesRelay.accept(remaining)
    refreshAggregate(batches: remaining)
}
```

这是任务 18 中弹出框 ViewModel 从 `Clear Failed` 按钮输入调用的方法。

- [ ] **Step 3: 更新 `refreshAggregate`，使 `hasAnyFailure` 考虑保留的批次**

已有的 `hasAnyFailure` 计算已经扫描 `batches` 中的 `.failed` 项，无需更改 —— 保留的失败批次会留在聚合状态中。

- [ ] **Step 4: 构建**

```bash
cd RuntimeViewerPackages && swift build 2>&1 | xcsift
```

- [ ] **Step 5: 提交**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
git commit -m "feat(application): retain failed batches + single reloadData per batch finish"
```

---

### 任务 25: 完整构建、跑测试、手动 QA

- [ ] **Step 1: 跑完整 Core 测试套件**

```bash
cd RuntimeViewerCore && swift test 2>&1 | xcsift
```

预期：所有测试通过。

- [ ] **Step 2: 完整构建 Packages**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages && swift package update && swift build 2>&1 | xcsift
```

- [ ] **Step 3: 构建 app**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer && xcodebuild build -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

- [ ] **Step 4: 手动 QA 清单**

启动 debug app 并逐项验证：

- [ ] Settings 中禁用 Background Indexing 时，toolbar 项显示淡化的 idle 图标，弹出框显示"已禁用"空状态。
- [ ] 在 Settings 启用开关会为 app 主可执行触发新批次；toolbar 图标开始旋转；弹出框显示批次及其项进展。
- [ ] 批次运行中减小 depth / maxConcurrency 不会影响该批次。
- [ ] 设置变更后启动的新批次使用新值（通过查看深度依赖树镜像的 `items.count` 验证）。
- [ ] 加载新镜像（File → Open）会启动以新镜像命名的第二个批次；两个批次并行进行。
- [ ] 点击批次的取消按钮（⊘）停止该批次；其未完成项变灰；当无批次时 toolbar 图标返回 idle。
- [ ] 弹出框中的 "Cancel All" 按钮取消所有批次。
- [ ] 在 sidebar 选中目前在批次中 pending 的镜像会让其弹出框行显示 `(priority)` 标签，并下一个运行。
- [ ] 包含无法解析 `@rpath` 依赖的镜像渲染为红色 ✗ 行，并显示 install name 与错误信息。
- [ ] 关闭 Document 取消其批次；该窗口的 toolbar 图标重置为 idle。

- [ ] **Step 5: 提交手动验证清单结果（可选）**

如果所有项都打勾，无需代码改动。否则在新任务中修复失败项，然后重新执行 Step 4。

---

### 任务 26: 提交 pull request

- [ ] **Step 1: 推送分支**

```bash
git push -u origin feature/runtime-background-indexing
```

- [ ] **Step 2: 创建 PR**

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

## 自审小结

- **规范覆盖:** evolution 提案的每一节都至少对应一个任务。
  - Package 接线（Semaphore 依赖）→ 任务 0。
  - 值类型（全部 `Hashable`）+ `ResolvedDependency` → 任务 1。
  - `DylibPathResolver` → 任务 2。
  - `Loaded vs Indexed` + `request/remote` 分发的 `isImageIndexed` → 任务 3。
  - Engine 新 API（`mainExecutablePath`、`loadImageForBackgroundIndexing`）带 `request/remote` → 任务 4；`imageDidLoadPublisher` → 任务 4.5。
  - Manager（协议 + mock、骨架、BFS、并发、取消、prioritize）→ 任务 5-10。
  - Engine 集成（非 `lazy` 存储 manager）→ 任务 11。
  - Settings → 任务 12-13。
  - Coordinator（生命周期、镜像加载、通过 `withObservationTracking` 观察 Settings）→ 任务 14-17。
  - UI（`MainRoute` 上的 Node + ViewModel、带 `preconditionFailure` 数据源的 VC、toolbar view + item、`MainRoute.backgroundIndexing` 注册）→ 任务 18-21。
  - 集成（Document 接线 + `runtimeEngine` 不变量 doc 注释）→ 任务 22。
  - Sidebar → prioritize → 任务 23。
  - 保留失败批次 + 刷新镜像列表 → 任务 24。
  - 手动 QA → 任务 25。
- **review 决策已落实:** 2026-04-24 review 中三条头部决策 —— 通过 `withObservationTracking` 处理 Settings（任务 17）、`BackgroundIndexingPopoverRoute` 合入 `MainRoute`（任务 18/21）、engine 方法的 `request/remote` 分发（任务 3/4）—— 均有专属任务与显式理由段落。
- **类型一致性:** `RuntimeIndexingBatchID`、`RuntimeIndexingBatch`、`RuntimeIndexingTaskState`、`RuntimeIndexingEvent`、`RuntimeIndexingBatchReason`、`RuntimeIndexingTaskItem`、`ResolvedDependency`、`BackgroundIndexingToolbarState`、`BackgroundIndexing`、`BackgroundIndexingNode`、`BackgroundIndexingPopoverViewModel`、`BackgroundIndexingPopoverViewController`、`BackgroundIndexingToolbarItem`、`BackgroundIndexingToolbarItemView`、`RuntimeBackgroundIndexingManager`、`RuntimeBackgroundIndexingCoordinator`、`DylibPathResolver`、`BackgroundIndexingEngineRepresenting` —— 所有交叉引用名称在定义任务与消费任务之间一致。任何位置都没有引入 `BackgroundIndexingPopoverRoute` 类型。
