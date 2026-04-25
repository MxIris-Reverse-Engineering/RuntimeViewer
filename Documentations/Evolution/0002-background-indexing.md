# 0002 - 后台索引

- **状态**: Accepted
- **作者**: JH
- **日期**: 2026-04-24
- **最后更新**: 2026-04-24

## 摘要

新增一个可选的 **后台索引（Background Indexing）** 功能，针对目标进程已加载镜像的依赖闭包，主动解析其 ObjC 与 Swift 元数据。工作由每个 `RuntimeEngine` 持有的 Swift Concurrency actor（`RuntimeBackgroundIndexingManager`）驱动，可在 Settings 中配置，通过 Toolbar 弹出框实时显示进度，并支持随时取消。

## 动机

Runtime Viewer 当前仅在用户显式打开某个镜像时才对其进行索引（解析 ObjC/Swift 元数据）。对于目标进程已经通过 dyld 加载的镜像 —— 例如 UIKit、Foundation 及其传递依赖闭包 —— 首次查询会因从未摊销的解析成本而出现可见延迟。

目标:

- 通过预解析常用镜像，降低用户在常见查询路径上感知到的延迟。
- 保留现有按需 `loadImage(at:)` 路径及其语义。
- 让用户通过 Settings 在 CPU 占用与响应速度之间权衡（depth、并发数）。
- 为运行中的工作提供实时可见性以及一键取消能力。

### 非目标

- 不在应用重启之间持久化索引历史（每次会话从干净状态开始）。
- 不支持单镜像（子批次）级取消 —— 仅支持批次级取消。
- 不支持暂停/恢复，仅支持启动 / 取消。
- 不自动重试失败项。
- 除单一手动 `prioritize(path:)` 钩子外，不引入额外 QoS 等级。
- 不引入空闲 / 低功耗启发式策略。无论系统负载如何，索引都会运行。
- 不向 MCP 工具暴露索引进度（MCP 消费的是结果，而不是进程状态）。
- 不在跨 Document / 跨 Engine 之间共享缓存（保留 dyld 层面已有的复用）。
- 不为旧调用方"loadImage == indexed"的混淆假设提供向后兼容垫片。

## 提议方案

### 背景上下文

来自头脑风暴和代码核验的事实来源:

- `RuntimeEngine`（actor）已经维护 `imageList: [String]`（所有 dyld 已知镜像）和 `loadedImagePaths: Set<String>`（我们通过 `loadImage(at:)` 处理过的镜像）。
- 单个镜像的索引目前发生在 `loadImage(at:)` 中：调用 `objcSectionFactory.section(for:)` 与 `swiftSectionFactory.section(for:)`，然后触发 `reloadData()`。
- `MachOImage.dependencies: [DependedDylib]` 提供依赖列表。MachOKit 将 `LC_LOAD_WEAK_DYLIB` 折叠为 `DependType.load`，因此实际上只会观察到 `.load`、`.reexport`、`.upwardLoad`、`.lazyLoad`。
- `Semaphore` 包（`groue/Semaphore`）已经为 `RuntimeViewerCommunication` 解析。在管理器可以 import 它之前，需要在 `RuntimeViewerCore` target 中显式声明为产品依赖。
- `MCPStatusPopoverViewController` + `MCPStatusToolbarItem` 是基于 Toolbar 锚定、RxSwift 驱动的弹出框模板。
- `RuntimeEngine` 暴露了 `request<T>(local:remote:)` 分发原语（`RuntimeEngine.swift:468`），用于每一个其结果依赖于目标进程的公共方法（local 与 XPC/TCP 之分）。本提案新增的所有引擎公共方法都使用同一原语。

### 术语：Loaded vs. Indexed

这一区分至关重要。

- **Loaded** —— 镜像已在目标进程中向 dyld 注册（出现在 `DyldUtilities.imageNames()` 中）。Loaded 并不能说明 Runtime Viewer 是否解析过其 ObjC / Swift 元数据。
- **Indexed** —— `RuntimeObjCSectionFactory` 和 `RuntimeSwiftSectionFactory` 都拥有针对该镜像路径的**成功解析后**缓存 section。解析失败**不**算作 indexed，这意味着失败路径会在下一批次中被重试（参见替代方案 D 解释为什么这是有意为之）。

新增 API —— `RuntimeEngine.isImageIndexed(path:)` —— 回答 indexed 这一问题。已有的 `isImageLoaded(path:)` 继续回答 loaded 这一问题。后台索引的去重始终使用 `isImageIndexed`。

### 架构

```
┌───────────────────────────────────────────────────────────────────┐
│  RuntimeViewerUsingAppKit (App target — 不带 Runtime 前缀)         │
│                                                                   │
│   Toolbar:    BackgroundIndexingToolbarItem (NSToolbarItem 子类)
│                + BackgroundIndexingToolbarItemView (NSProgressIndicator
│                  覆盖在 SFSymbol 图标上)                          │
│                                                                   │
│   Popover:   BackgroundIndexingPopoverViewController              │
│                + BackgroundIndexingPopoverViewModel (ViewModel<MainRoute>)
│                + BackgroundIndexingNode 枚举 (batch / item)       │
└───────────────────────────────────────────────────────────────────┘
                                ↕ RxSwift（仅用于 UI 绑定层）
┌───────────────────────────────────────────────────────────────────┐
│  RuntimeViewerApplication（新类型带 Runtime 前缀）                │
│                                                                   │
│   RuntimeBackgroundIndexingCoordinator (class)                    │
│     ·  订阅 Document 生命周期与引擎镜像加载事件                   │
│     ·  通过 withObservationTracking 观察 Settings.backgroundIndexing
│     ·  调用 engine.backgroundIndexingManager.startBatch(...)      │
│     ·  将管理器的 AsyncStream<Event> 桥接为弹出框消费的           │
│        Observable<[RuntimeIndexingBatch]>（RxSwift）              │
│     ·  暴露聚合状态 (Driver<IndexingToolbarState>)                │
└───────────────────────────────────────────────────────────────────┘
                                ↕ async / await
┌───────────────────────────────────────────────────────────────────┐
│  RuntimeViewerCore（新类型带 Runtime 前缀）                       │
│                                                                   │
│   RuntimeEngine (actor，已有)                                     │
│     + var backgroundIndexingManager: RuntimeBackgroundIndexingManager
│     + func isImageIndexed(path:) async throws -> Bool   (request/remote)
│     + func mainExecutablePath() async throws -> String  (request/remote)
│     + func loadImageForBackgroundIndexing(at:) async throws (request/remote)
│     + nonisolated var imageDidLoadPublisher: some Publisher<String, Never>
│                                                                   │
│   RuntimeBackgroundIndexingManager (actor，新增 —— 核心)          │
│     公共 API:                                                     │
│       · events: AsyncStream<RuntimeIndexingEvent>                 │
│       · batches: [RuntimeIndexingBatch]                           │
│       · startBatch(rootImagePath:depth:maxConcurrency:reason:)    │
│              -> RuntimeIndexingBatchID                            │
│       · cancelBatch(_:)                                           │
│       · cancelAllBatches()                                        │
│       · prioritize(imagePath:)                                    │
│     内部:                                                         │
│       · activeBatches: [RuntimeIndexingBatchID: BatchState]       │
│       · 每批次一个 AsyncSemaphore 控制并发                        │
│       · 每批次一个驱动 Task，托管一个 TaskGroup                   │
│                                                                   │
│   Sendable 值类型（全部 Hashable）:                               │
│     RuntimeIndexingBatch, RuntimeIndexingBatchID,                 │
│     RuntimeIndexingTaskItem, RuntimeIndexingTaskState,            │
│     RuntimeIndexingEvent, RuntimeIndexingBatchReason,             │
│     ResolvedDependency                                            │
│                                                                   │
│   工具:                                                           │
│     DylibPathResolver —— 基于 rpaths 与镜像路径解析               │
│     @rpath / @executable_path / @loader_path 形式的 install name  │
└───────────────────────────────────────────────────────────────────┘
```

### 远程分发模型

新增的所有 `RuntimeEngine` 公共方法 —— `isImageIndexed`、`mainExecutablePath`、`loadImageForBackgroundIndexing` —— 都包裹在已有的 `request<T>(local:remote:)` 原语之内。该原语当前为 `private`（`RuntimeEngine.swift:468`），但新增的 API 以及前两个 factory 都放在跨文件扩展 `RuntimeEngine+BackgroundIndexing.swift` 中实现 —— Swift 的 `private` 不允许跨文件 extension 访问，因此 `request<T>` 与两个 factory 必须提至 `internal`：

```swift
public func isImageIndexed(path: String) async throws -> Bool {
    try await request {
        objcSectionFactory.hasCachedSection(for: path)
            && swiftSectionFactory.hasCachedSection(for: path)
    } remote: { senderConnection in
        try await senderConnection.sendMessage(
            name: .isImageIndexed, request: path)
    }
}
```

新增三个 `CommandNames` 枚举值 —— `.isImageIndexed`、`.mainExecutablePath`、`.loadImageForBackgroundIndexing` —— 同时服务端处理表（`RuntimeEngine.swift:276-302`）增加：

```swift
setMessageHandlerBinding(forName: .isImageIndexed,            of: self) { $0.isImageIndexed(path:) }
setMessageHandlerBinding(forName: .mainExecutablePath,        of: self) { $0.mainExecutablePath }
setMessageHandlerBinding(forName: .loadImageForBackgroundIndexing, of: self) { $0.loadImageForBackgroundIndexing(at:) }
```

`RuntimeBackgroundIndexingManager` 与 engine 一对一构造,**实例始终活在客户端进程内**(参见 Assumption #2)。manager 通过 `BackgroundIndexingEngineRepresenting` 协议消费 engine,而 engine 的方法实现内部走 `request { local } remote: { RPC }` —— 本地源(DyldSharedCache / file)在客户端就近完成索引;远程源(XPC / directTCP)的实际索引工作在服务端目标进程执行。manager 自身的事件、批次状态、取消 API 都在客户端进程内,UI 通过 coordinator 直接消费,**不**通过 XPC 镜像;镜像化留作后续工作。

### 组件

#### `RuntimeBackgroundIndexingManager`（actor）

持有所有运行中的批次以及所有事件流。在 `RuntimeEngine` init 时创建,**通过协议 `BackgroundIndexingEngineRepresenting` 按值持有引擎**(`engine: any BackgroundIndexingEngineRepresenting`):manager 不直接依赖具体的 `RuntimeEngine` 类型,只通过协议表面消费 `isImageIndexed` / `mainExecutablePath` / `loadImageForBackgroundIndexing` / `canOpenImage` / `rpaths` / `dependencies` 等方法。`RuntimeEngine`(actor)只是该协议的一个 conformance,测试用 `MockBackgroundIndexingEngine`(`@unchecked Sendable`)与 `InstrumentedEngine` 同样 conform。这条 seam 让 manager 单元测试不需要真实 dyld I/O,也避免 actor↔actor 之间的 `unowned` 反向引用。

```swift
public actor RuntimeBackgroundIndexingManager {
    private let engine: any BackgroundIndexingEngineRepresenting

    public nonisolated var events: AsyncStream<RuntimeIndexingEvent> { ... }

    init(engine: any BackgroundIndexingEngineRepresenting)

    public func startBatch(
        rootImagePath: String,
        depth: Int,
        maxConcurrency: Int,
        reason: RuntimeIndexingBatchReason
    ) async -> RuntimeIndexingBatchID

    public func cancelBatch(_ id: RuntimeIndexingBatchID)
    public func cancelAllBatches()
    public func prioritize(imagePath: String)
    public func currentBatches() -> [RuntimeIndexingBatch]
}
```

#### `BackgroundIndexingEngineRepresenting`（协议）

manager 与具体 engine 类型之间的抽象 seam。仅 `: Sendable`(无 `AnyObject` —— manager 按值持有,无引用语义需求;参见决策日志 2026-04-26)。

```swift
protocol BackgroundIndexingEngineRepresenting: Sendable {
    func isImageIndexed(path: String) async throws -> Bool
    func loadImageForBackgroundIndexing(at path: String) async throws
    func mainExecutablePath() async throws -> String
    func canOpenImage(at path: String) async -> Bool
    func rpaths(for path: String) async throws -> [String]
    func dependencies(for path: String)
        async throws -> [(installName: String, resolvedPath: String?)]
}
```

要点:

- **不暴露 `MachOImage`**:该类型为非 Sendable 结构体(包含 unsafe pointer),跨 actor 边界返回会触发 Swift 6 严格并发错误。需要门控递归的调用方走 `canOpenImage(at:)`,需要查依赖的走 `dependencies(for:)`(在 conformance 实现里 actor 隔离地调用 `MachOImage`)。
- **几乎所有方法都是 `async throws`**:`RuntimeEngine` conformance 内部走 `request { local } remote: { RPC }`,远程分支(XPC / directTCP)可能抛错。`canOpenImage` 是纯本地查询,保持 non-throwing。
- **conformances**:
  - `extension RuntimeEngine: BackgroundIndexingEngineRepresenting`(生产路径,actor)
  - `final class MockBackgroundIndexingEngine: BackgroundIndexingEngineRepresenting, @unchecked Sendable`(单元测试)
  - `final class InstrumentedEngine: BackgroundIndexingEngineRepresenting, @unchecked Sendable`(并发计数测试包装器)

#### Sendable 值类型

```swift
public struct RuntimeIndexingBatchID: Hashable, Sendable { public let raw: UUID }

public enum RuntimeIndexingBatchReason: Sendable, Hashable {
    case appLaunch
    case imageLoaded(path: String)
    case manual
    case settingsEnabled
}

public enum RuntimeIndexingTaskState: Sendable, Hashable {
    case pending
    case running
    case completed
    case failed(message: String)
    case cancelled
}

public struct RuntimeIndexingTaskItem: Sendable, Identifiable, Hashable {
    public let id: String          // 镜像路径（未解析时为 install name）
    public let resolvedPath: String?
    public var state: RuntimeIndexingTaskState
    public var hasPriorityBoost: Bool
}

public struct RuntimeIndexingBatch: Sendable, Identifiable, Hashable {
    public let id: RuntimeIndexingBatchID
    public let rootImagePath: String
    public let depth: Int
    public let reason: RuntimeIndexingBatchReason
    public var items: [RuntimeIndexingTaskItem]
    public var isCancelled: Bool
    public var isFinished: Bool
}

public struct ResolvedDependency: Sendable, Hashable {
    public let installName: String
    public let resolvedPath: String?
}

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

所有值类型都是 `Hashable`，因此可以无需额外 conformance 工作就组合成 `BackgroundIndexingNode: Hashable`。

#### `RuntimeBackgroundIndexingCoordinator`

每个 Document 创建一份(由 `DocumentState` 持有)。**`@MainActor` 隔离类**(与 `DocumentState` 一致),所有事件归约、Settings 观察、UI 状态发布都在主线程,不需要内部 `MainActor.run` 跳转。职责:

1. 通过 `withObservationTracking` 观察 `Settings.backgroundIndexing`（参见 Settings 章节）→ 启用 / 禁用 / 重启。
2. 监听引擎的 `imageDidLoadPublisher` → 为该镜像启动一次依赖批次。
3. 监听 Sidebar 的镜像选中信号 → 调用 `manager.prioritize(path:)`。
4. 将 `manager.events`（AsyncStream）桥接到 `eventRelay: PublishRelay<RuntimeIndexingEvent>`（RxSwift）。
5. 维护从事件归约而来的 `batchesRelay: BehaviorRelay<[RuntimeIndexingBatch]>`。**包含任意失败项的已完成批次会被保留**在 `batchesRelay` 中，直到用户在弹出框中通过"Clear Failed"显式清除；干净完成与取消会立即移除。
6. 暴露 `aggregateStateDriver: Driver<IndexingToolbarState>`。`hasFailures` 由保留下来的失败批次推导。
7. 持有按 Document 维度的批次跟踪：`[Document.ID: Set<RuntimeIndexingBatchID>]`。

### 数据流场景

#### 场景 A —— 启用了索引时的应用启动 / Document 打开

```
Document 打开
  → DocumentState ready，RuntimeEngine 可用
  → Coordinator.documentDidOpen(documentState)
      读取 Settings.backgroundIndexing
      若 !isEnabled → return
      rootPath = try await engine.mainExecutablePath()
      batchID = await engine.backgroundIndexingManager.startBatch(
          rootImagePath: rootPath,
          depth: settings.depth,
          maxConcurrency: settings.maxConcurrency,
          reason: .appLaunch)
      Toolbar 项从 idle 切换到 indexing
```

#### 场景 B —— 用户在运行时加载新镜像

```
用户操作 → documentState.loadImage(at: path)
  → RuntimeEngine.loadImage(at:)（已有路径完成）
  → Engine 发出 imageDidLoadPublisher(path)
  → Coordinator（若 isEnabled）:
      batchID = manager.startBatch(
          rootImagePath: path,
          depth: settings.depth,
          maxConcurrency: settings.maxConcurrency,
          reason: .imageLoaded(path: path))
      依赖图扩展会跳过已索引的项
```

#### 场景 C —— 用户选中已经在队列中的镜像

```
Sidebar 选中变化 → SidebarViewModel 发出 imageSelected(path)
  → Coordinator → manager.prioritize(imagePath: path)
      manager 遍历 activeBatches，找到匹配 path 的 pending 项
      标记 hasPriorityBoost = true，加入 priorityBoostPaths 集合
      发出 .taskPrioritized
      正在运行 / 已完成 / 不存在的路径：静默 no-op
```

#### 场景 D —— Document 关闭

```
Document.close()
  → Coordinator.documentWillClose(documentState)
      for batchID in Coordinator.batchesFor(document):
          await manager.cancelBatch(batchID)
      移除 document 条目
```

#### 场景 E —— Settings 切换（通过 `withObservationTracking`）

```
Coordinator.subscribeToSettings():
    withObservationTracking {
        let snapshot = Settings.shared.backgroundIndexing
        _ = snapshot.isEnabled
        _ = snapshot.depth
        _ = snapshot.maxConcurrency
    } onChange: { [weak self] in
        Task { @MainActor in
            self?.handleSettingsChange()
            self?.subscribeToSettings()   // 重新注册
        }
    }

handleSettingsChange:
    isEnabled false → true:
        对每个打开的 Document 执行场景 A（root = mainExecutablePath）
        （不要回放历史 loadImage 调用）
    isEnabled true → false:
        await manager.cancelAllBatches()
    启用状态下 depth / maxConcurrency 变化:
        对运行中的批次为 no-op；新值在下一次 startBatch 生效。
```

理由：`Settings` 已经声明为 `@Observable`，`withObservationTracking` 是原生匹配。在 `onChange` 中重新注册是文档化的"一次性观察者"恢复模式；它在每次 settings 变化中都让观察者保持存活，且不引入 Combine 基础设施。

#### 场景 F —— 用户从弹出框取消

```
弹出框 Cancel 按钮 → ViewModel cancelBatchRelay.accept(batchID)
  → Coordinator → await manager.cancelBatch(id)
      批次的驱动 Task → task.cancel()
      TaskGroup 子任务继承取消
      runSingleIndex 捕获 CancellationError → 项状态 .cancelled
      已完成项保留 .completed
      发出 .batchCancelled
```

### 依赖图扩展

由 manager 内部的 `expandDependencyGraph(rootPath:depth:)` 实现。在 `startBatch` 开始时同步运行，因此在第一个 `taskStarted` 事件触发之前批次的总项数就已知 —— 这让弹出框的进度条从第一帧就保持准确。

```swift
// 伪代码
func expandDependencyGraph(rootPath: String, depth: Int) async
    -> [RuntimeIndexingTaskItem]
{
    var visited: Set<String> = []
    var items: [RuntimeIndexingTaskItem] = []
    var frontier: [(path: String, level: Int)] = [(rootPath, 0)]

    while !frontier.isEmpty {
        let (path, level) = frontier.removeFirst()
        guard visited.insert(path).inserted else { continue }

        if await engine.isImageIndexed(path: path) { continue }

        items.append(.init(id: path, resolvedPath: path,
                           state: .pending, hasPriorityBoost: false))
        guard level < depth else { continue }

        for dep in await engine.dependencies(for: path) {
            if let resolved = dep.resolvedPath {
                if !visited.contains(resolved) {
                    frontier.append((resolved, level + 1))
                }
            } else if visited.insert(dep.installName).inserted {
                items.append(.init(id: dep.installName, resolvedPath: nil,
                                   state: .failed(message: "path unresolved"),
                                   hasPriorityBoost: false))
            }
        }
    }
    return items
}
```

我们允许的深度（≤ 5）下，`Array.removeFirst()` 已经够用；不需要双端队列。

#### 依赖类型筛选

- **包含**: `.load`、`.reexport`、`.upwardLoad`。
- **跳过**: `.lazyLoad` —— 懒加载的 dylib 在运行时可能从不真正加载，主动解析它们既是猜测又是浪费。

`LC_LOAD_WEAK_DYLIB` 被 MachOKit 解码为 `DependType.load`（参见 `MachOImage.swift:168-173`）；`.weakLoad` 这一枚举值永远不会从 `dependencies` 出现，无需显式分支。

#### 路径解析（`DylibPathResolver`）

install name 有四种形态:

| 形态 | 解析 |
|-------|------------|
| `/System/Library/...`（绝对路径） | 原样使用，校验文件存在。 |
| `@rpath/Foo.framework/Foo` | 对根镜像上每个 `LC_RPATH` 进行替换，取第一个存在的路径。 |
| `@executable_path/...` | 用主可执行文件所在目录替换。 |
| `@loader_path/...` | 用当前镜像所在目录替换。 |

返回 `String?` —— `nil` 映射为 `.failed("path unresolved")` 且不递归的 task item。

### 并发模型

完全基于 Swift Concurrency —— 工作路径中没有 `OperationQueue`、没有 `DispatchQueue`、没有 RxSwift。RxSwift 仅用于 coordinator 内的 UI 绑定层。

```swift
// Manager 内部（草图）
private func runBatch(id: RuntimeIndexingBatchID) async {
    let state = activeBatches[id]!
    eventsContinuation.yield(.batchStarted(state.batch))

    let semaphore = AsyncSemaphore(value: state.maxConcurrency)
    await withTaskGroup(of: Void.self) { group in
        while let item = popNextPrioritizedPending(batchID: id) {
            try? await semaphore.waitUnlessCancelled()
            if Task.isCancelled { break }
            group.addTask { [weak self] in
                defer { Task { await semaphore.signal() } }
                await self?.runSingleIndex(batchID: id, path: item.id)
            }
        }
    }

    finalizeBatch(id)    // 发出 .batchFinished 或 .batchCancelled
}

private func runSingleIndex(batchID: RuntimeIndexingBatchID,
                            path: String) async {
    updateItemState(batchID, path, .running)
    eventsContinuation.yield(.taskStarted(batchID: batchID, path: path))
    do {
        try Task.checkCancellation()
        try await engine.loadImageForBackgroundIndexing(at: path)
        updateItemState(batchID, path, .completed)
        eventsContinuation.yield(.taskFinished(
            batchID: batchID, path: path, result: .completed))
    } catch is CancellationError {
        updateItemState(batchID, path, .cancelled)
    } catch {
        let message = error.localizedDescription
        updateItemState(batchID, path, .failed(message: message))
        eventsContinuation.yield(.taskFinished(
            batchID: batchID, path: path, result: .failed(message: message)))
    }
}
```

#### 优先级队列机制

每个批次状态持有一个 pending 路径的 `Array<String>` 以及 priority-boost 成员的 `Set<String>`。`prioritize(imagePath:)` 仅修改集合（并发出 `.taskPrioritized`）；pop 辅助函数会先在 pending 数组中扫描第一个被 boost 的路径，没有 boost 时退化为数组头部。优先级无法抢占已经在运行的子任务 —— Swift 结构化并发不支持。对运行中或已完成的路径调用 `prioritize` 是静默 no-op。

#### `AsyncSemaphore`

来自 `groue/Semaphore`。该依赖在 package 层已经解析，但仅声明给 `RuntimeViewerCommunication`；本提案在 `RuntimeViewerCore` target 的 dependencies 列表中显式添加 `.product(name: "Semaphore", package: "Semaphore")`。

#### UI 刷新抑制

`loadImageForBackgroundIndexing(at:)` **不**调用 `reloadData()`。在一次批次中调用 N 次会让 sidebar 被洪水攻击。Coordinator 在每次 `.batchFinished` / `.batchCancelled` 事件触发时调用一次 `await engine.reloadData(isReloadImageNodes: false)`，让 sidebar 在一次更新中拉起新索引的图标。

### Settings

#### `BackgroundIndexing` 结构体（`Settings+Types.swift`）

```swift
@Codable @MemberInit public struct BackgroundIndexing {
    @Default(false) public var isEnabled: Bool
    @Default(1)     public var depth: Int               // 有效区间 1...5
    @Default(4)     public var maxConcurrency: Int      // 有效区间 1...8
    public static let `default` = Self()
}
```

添加到根 `Settings` 类（已为 `@Observable`）作为：

```swift
@Default(BackgroundIndexing.default)
public var backgroundIndexing: BackgroundIndexing = .init() {
    didSet { scheduleAutoSave() }
}
```

由已有的 `SettingsFileSystemStorage` 自动保存持久化。不向 `Settings` 添加 Combine publisher。

#### `BackgroundIndexingSettingsView`（SwiftUI）

位于 `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/BackgroundIndexingSettingsView.swift`。通过在 `SettingsRootView.swift` 新增的 `SettingsPage.backgroundIndexing` case 进入（图标 `square.stack.3d.down.right`，标题 `"Background Indexing"`）。

Form 内容：
- `Toggle "Enable background indexing"` 绑定 `$settings.isEnabled`。
- 解释行为的说明段落。
- depth 的 `Stepper`（1...5），附带说明语义。
- maxConcurrency 的 `Stepper`（1...8），附带说明 CPU 取舍。

Cancel-all 留在弹出框页脚，不放入 Settings。

#### Settings 变更传播

Coordinator 通过 `withObservationTracking` 订阅 `Settings.shared.backgroundIndexing`，并在 `onChange` 内重新注册。具体流程参见场景 E。

### UI: Toolbar Item + 弹出框

#### `BackgroundIndexingToolbarItem`

`NSToolbarItem` 子类，在 `MainToolbarController.swift` 注册。标识符 `backgroundIndexing`。在默认与允许的标识符列表中放置在已有的 `mcpStatus` 项旁边（已有的 case 字面量是 `mcpStatus(sender:)`，而非 `mcpStatusPopover`）。

`view` 是 `BackgroundIndexingToolbarItemView`（NSView），中间放一个 16pt 的图标（SF Symbol `square.stack.3d.down.right`），当状态为 `indexing` 或 `hasFailures` 时叠加一个 `NSProgressIndicator(style: .spinning)`。`hasFailures` 时会在右下角绘制一个小红点徽标。

`IndexingToolbarState` 枚举：`.idle`、`.disabled`、`.indexing(percent: Double?)`、`.hasFailures(percent: Double?)`。

view 通过 toolbar 构建时弱持有的 observer 集合绑定到 coordinator 推送的 `Driver<IndexingToolbarState>`。

点击该项触发**已有**的 `MainRoute` 表面新增的 case：

```swift
case backgroundIndexing(sender: NSView)
```

注意名称**没有 `Popover` 后缀**，与同级的 `mcpStatus(sender:)` 保持一致。

#### `BackgroundIndexingPopoverViewController`

基类 `UXKitViewController<BackgroundIndexingPopoverViewModel>`。ViewModel 是 `ViewModel<MainRoute>` —— **没有**单独的 `BackgroundIndexingPopoverRoute`。需要 `MainRoute` 路由的动作(目前只有 `dismiss`)走主层级已有 case;**`Open Settings` 不走 router**,因为 `MainRoute` 没有也不会增加 `openSettings` case —— ViewController 直接调用 `SettingsWindowController.shared.showWindow(nil)`,与 `MCPStatusPopoverViewController.swift:200-203` 的处理方式一致。固定宽度 380,高度从约 120(空状态)到 400(带滚动的大纲视图)。

内容布局：

- 头部：`Label("Background Indexing")` 加一个读取聚合进度的副标题 `Label`。
- 空状态 A（已禁用）：图标 + "Background indexing is disabled" + `"Open Settings"` 按钮。
- 空状态 B（已启用、无批次）：图标 + "No active indexing tasks"。
- 主体：渲染 `BackgroundIndexingNode` 的 `StatefulOutlineView`。
- 页脚：`HStackView`，包含 `Cancel All` 按钮（无活动批次时禁用）、`Clear Failed` 按钮（仅当存在保留的失败批次时可见）以及 `Close` 按钮。

`BackgroundIndexingNode`:

```swift
enum BackgroundIndexingNode: Hashable {
    case batch(RuntimeIndexingBatch)
    case item(batchID: RuntimeIndexingBatchID, item: RuntimeIndexingTaskItem)
}
```

大纲单元格:

- Batch 行：标题由 `reason` 派生、`"{completed}/{total}"`，以及一个 cancel 按钮。点击 cancel 会触发 `cancelBatchRelay.accept(batchID)`。
- Item 行：状态图标（pending 灰点 / running 旋转 / completed 绿色 ✓ / failed 红色 ✗ / cancelled 灰色 ⊘）+ 显示名 + 副标签。失败行展示完整 install name 与错误信息。`hasPriorityBoost == true` 的行展示一个 `"priority"` 标签。

防御性的大纲数据源分支使用 `preconditionFailure("unexpected outline item type")`，而不是返回零初始化的 batch，这样错误绑定的调用方会立即暴露。

#### `BackgroundIndexingPopoverViewModel`

```swift
final class BackgroundIndexingPopoverViewModel: ViewModel<MainRoute> {
    @Observed private(set) var nodes: [BackgroundIndexingNode] = []
    @Observed private(set) var isEnabled: Bool = false
    @Observed private(set) var hasAnyBatch: Bool = false
    @Observed private(set) var hasAnyFailure: Bool = false
    @Observed private(set) var subtitle: String = ""

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
        // Forwarded to the ViewController, which calls
        // `SettingsWindowController.shared.showWindow(nil)` directly.
        let openSettings: Signal<Void>
    }

    func transform(_ input: Input) -> Output { ... }
}
```

`isEnabled` 通过与 coordinator **相同**的 `withObservationTracking` 重新注册循环与 `Settings.shared.backgroundIndexing.isEnabled` 保持同步 —— 不是在 `transform` 中读一次后遗忘。这样弹出框打开时它的空状态会随 Settings 切换而响应。`hasAnyFailure` 由 coordinator 的 `aggregateState` 派生,驱动 `Clear Failed` 按钮的可见性。

`input.openSettings` 在 `transform` 内被中转到 `output.openSettings`(经一个内部 `PublishRelay`);ViewController 在 `setupBindings` 中订阅 `output.openSettings` 并直接调用 `SettingsWindowController.shared.showWindow(nil)` —— 见 `MCPStatusPopoverViewController.swift:200-203` 的同款先例。**不**经 `router.trigger(.openSettings)`,因为 `MainRoute` 没有该 case。

### 错误处理

| 失败位置 | 行为 | UI |
|---|---|---|
| 图扩展时 `MachOImage(name: path)` 返回 nil | 项 → `.failed("cannot open MachOImage")`，不递归 | 红色 ✗ + tooltip |
| `@rpath` / `@executable_path` / `@loader_path` 未解析 | 项 → `.failed("path unresolved")`，不递归 | 红色 ✗ + 原始 install name |
| `DyldUtilities.loadImage` 抛出（codesign、sandbox、文件缺失） | 项 → `.failed(dlopenError.localizedDescription)` | 红色 ✗ |
| ObjC section 解析抛出 | 项 → `.failed(objcParseError)` | 红色 ✗ |
| Swift section 解析抛出 | 项 → `.failed(swiftParseError)`。`isImageIndexed` 仍为 false，因为至少一个 factory 没有该路径的缓存 | 红色 ✗ |
| `Task.checkCancellation` 抛出 | 项 → `.cancelled`，不发出错误事件 | 灰色 ⊘ |
| Coordinator 在 Document 释放后收到事件 | `[weak self]` 静默丢弃事件 | — |

`isImageIndexed(path:)` 要求**两个** factory 都有成功缓存的条目。解析失败不会留下缓存项，因此该路径会重新进入下一批次的 frontier。这是有意为之 —— 参见替代方案 D。

### 竞态 / 边界条件

1. **用户对正在被后台批次索引的相同路径执行手动 `loadImage(path)`。**
   ObjC / Swift factory 必须按路径串行化解析，使两个并发调用方不会同时解析。规划阶段会核验（如有需要，会在每个 factory 中引入 `[String: Task<Section, Error>]` 形式的 in-flight map）。

2. **批次取消时部分项已完成。**
   已完成项保留 `.completed`；`loadedImagePaths` 的插入不会回滚。在解析过程中收到 `CancellationError` 的 in-flight 项可能在 factory 中留下部分 section —— 本次迭代可接受；`isImageIndexed` 之后会返回 false，未来的显式加载会重做工作。

3. **同一根镜像的多个批次。**
   manager 去重：如果某活动批次的 `rootImagePath == root` 且 `reason` 的判别式匹配，返回其已有 `RuntimeIndexingBatchID` 而非新启动一个。

4. **事件传输中 Document 关闭。**
   引擎（及其 manager）deinit 时会调用 `AsyncStream.Continuation.finish()`。Coordinator 的 `Task { for await event in manager.events }` 会干净退出。

### 假设

1. **`DocumentState.runtimeEngine` 在 Document 整个生命周期内不可变。** 该属性出于历史原因被声明为 `@Observed public var runtimeEngine: RuntimeEngine = .local`（`DocumentState.swift:10-11`），但调用方在 Document 创建后不会重新赋值。Coordinator 在 init 时一次性捕获 `engine = documentState.runtimeEngine`；如果该假设被打破，批次会被分发到错误的 engine。在该属性上加一段文档注释强化此契约。

2. **`RuntimeBackgroundIndexingManager` 与 engine 一对一构造,在客户端进程内活着。** 对于远程(XPC / directTCP)来源,manager 实例仍在客户端运行,但其内部调用的 engine 公共方法(`isImageIndexed` / `mainExecutablePath` / `loadImageForBackgroundIndexing` / `dependencies(for:)` 等)都走 `request { local } remote: { RPC }` 分发,真正的索引工作由服务端目标进程执行。UI 客户端通过本地引擎引用消费 manager 事件流。

3. **Settings 修改频率较低。** `withObservationTracking` 重新注册在每次属性变更时触发一次。由于 Settings 的滑块 / toggle 以人类 UI 节奏运行，重新注册的成本可忽略不计。

### 测试策略

放在 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/` 下。

1. `DylibPathResolverTests`
   - `@rpath` 单条 + 多条 `LC_RPATH`，命中 + 未命中。
   - `@executable_path` 与 `@loader_path` 替换。
   - 绝对路径直通。
2. `RuntimeBackgroundIndexingManagerTests` 使用一个遵循新内部协议 `BackgroundIndexingEngineRepresenting` 的 `MockBackgroundIndexingEngine`（`@unchecked Sendable`）。
   - 深度 0、1、2 的图扩展；已索引短路。
   - `prioritize` 让下一次分发选中被 boost 的路径。**基于时间的断言被替换为基于事件顺序的断言**（`taskStarted` 顺序），避免 CI 不稳定。
   - `cancelBatch` 终止 in-flight 工作，将剩余 pending 项标记为 cancelled。
   - 并发上限被遵守（spy 计数器永不超过配置值）。
   - 事件顺序：`batchStarted` 早于任何 `taskStarted`；`batchFinished` 最后。
3. 如果 coordinator 端最终承担了非平凡的归约逻辑，则补充 `RuntimeIndexingBatch` / 事件 reducer 测试。

UI 不做自动化（没有现成的 UI 测试 harness）；plan 包含一份手动验证清单。

### 文件清单

#### 新增文件

```
RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/
    RuntimeBackgroundIndexingManager.swift
    RuntimeIndexingBatch.swift
    RuntimeIndexingBatchID.swift
    RuntimeIndexingBatchReason.swift
    RuntimeIndexingTaskItem.swift
    RuntimeIndexingTaskState.swift
    RuntimeIndexingEvent.swift
    ResolvedDependency.swift
    BackgroundIndexingEngineRepresenting.swift
RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/
    DylibPathResolver.swift
RuntimeViewerCore/Sources/RuntimeViewerCore/
    RuntimeEngine+BackgroundIndexing.swift

RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/
    DylibPathResolverTests.swift
    RuntimeBackgroundIndexingManagerTests.swift
    MockBackgroundIndexingEngine.swift

RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/
    BackgroundIndexingSettingsView.swift

RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/
    RuntimeBackgroundIndexingCoordinator.swift

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/
    BackgroundIndexingToolbarItem.swift
    BackgroundIndexingToolbarItemView.swift
    BackgroundIndexingPopoverViewController.swift
    BackgroundIndexingPopoverViewModel.swift
    BackgroundIndexingNode.swift
```

注意没有 `BackgroundIndexingPopoverRoute.swift` —— 路由通过 `MainRoute`。

#### 修改的文件

```
RuntimeViewerCore/Package.swift
    + 在 RuntimeViewerCore target 增加 .product(name: "Semaphore", package: "Semaphore")

RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift
    + BackgroundIndexing 结构体

RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift
    + backgroundIndexing 属性

RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift
    + SettingsPage.backgroundIndexing case 与 contentView 分支

RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
    + backgroundIndexingManager 存储属性（在 init 末尾设置）
    + isImageIndexed(path:)，使用 request/remote 分发
    + mainExecutablePath()，使用 request/remote 分发
    + loadImageForBackgroundIndexing(at:)，使用 request/remote 分发
    + imageDidLoadPublisher（PassthroughSubject<String, Never>）
    + 在 loadImage(at:) 成功时发出 imageDidLoadSubject.send(path)
    + objcSectionFactory / swiftSectionFactory 访问级别提升至 internal
    + 为三个新方法新增 CommandNames + setMessageHandlerBinding 处理器

RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift
RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
    + hasCachedSection(for:) 查询接口
    + 可选的按路径 in-flight 去重（plan 验证）

RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift
    + backgroundIndexingCoordinator 属性
    + 文档注释，断言 runtimeEngine 不可变

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainRoute.swift
    + backgroundIndexing(sender:) case（不带 "Popover" 后缀）

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift
    + backgroundIndexing 项标识符 + 工厂
    + wireBackgroundIndexing(item:) 绑定

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift
    + backgroundIndexing(sender:) 转换 case

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift
    + 调用 coordinator.documentDidOpen / documentWillClose
```

`RuntimeViewerUsingAppKit/.../BackgroundIndexing/` 下所有新文件必须手动加入 Xcode 项目（与 project memory 中提到的 MCPServer 模式一致）。

## 替代方案考量

### A. 通过新增的 `Combine.PassthroughSubject` 订阅 `Settings`

在 `Settings` 上加一个 `PassthroughSubject<Settings, Never>`，从 `scheduleAutoSave` 中发出，让 coordinator 用 Combine 订阅。被否决，因为 `Settings` 已是 `@Observable` —— 增加一条平行 Combine 通道会复制事实来源，并迫使未来的读者二选一。`withObservationTracking` 是原生匹配，且对我们观察的少量属性可以扩展。

### B. 单独的 `BackgroundIndexingPopoverRoute` 枚举

镜像 `MCPStatusPopover` 的结构，定义一个专属的 Route 枚举。被否决，因为 `MainCoordinator` 已经绑定到 `SceneCoordinator<MainRoute, MainTransition>`；增加第二个、有条件的 `Router` conformance 无法编译。考虑过通过单独的 adapter 转发，但比直接给 `MainRoute` 加一个 case（仅一行成本）更重。

### C. 不分发的、仅本地的 engine 扩展

让 `isImageIndexed` / `mainExecutablePath` / `loadImageForBackgroundIndexing` 保持纯本地读取（不包裹 `request { local } remote: { RPC }`）。被否决，因为当 document 目标是远程源（XPC / directTCP）时这会静默返回错误数据 —— 本地 engine 对远程进程已加载的镜像一无所知。

### D. 缓存空 / nil 解析结果以建立"已尝试"位

让 `hasCachedSection(for:)` 把解析失败也算作已索引，从而避免重试。被否决：factory 缓存目前存的是成功的 `Section` 值，引入 `Result<Section, Error>` 或并行的 `attemptedFailures` 集合会传播到许多调用点。更简单的语义 —— "indexed" = "成功解析" —— 意味着失败路径会在下一批次中重试，鉴于实际中确定性但可恢复的解析失败相当少见，这一选择可接受。

### E. UI 立即丢弃已完成 / 已取消的批次

更简单的归约逻辑：`.batchFinished` / `.batchCancelled` 到达时从 coordinator relay 中移除批次，弹出框就忘掉它存在过。被否决，因为失败的批次承载着可操作信息；静默丢失它们意味着 toolbar 的 `hasFailures` 指示器永远不会浮现。改为：包含任何 `.failed` 项的已完成批次会被保留，直到用户点击弹出框中的 `Clear Failed`。

## 影响

- **破坏性变更**: 无。该功能是可选的（默认关闭），且不修改既有 `loadImage(at:)` 的语义。
- **受影响文件**: 见上文文件清单。
- **是否需要迁移**: 不需要。Settings 默认值由已有的 `@Codable` 路径写入；缺失键回退到 `@Default` 值。

## 决策日志

| 日期 | 决策 | 理由 |
|------|----------|--------|
| 2026-04-24 | 创建为 Draft | 规范来自针对可选、基于 Swift Concurrency 的 dyld 已加载依赖闭包后台索引的头脑风暴 |
| 2026-04-24 | Settings 订阅 → `withObservationTracking` | `Settings` 是 `@Observable`；避免平行 Combine 通道 |
| 2026-04-24 | `BackgroundIndexingPopoverRoute` 合入 `MainRoute` | `MainCoordinator` 是 `SceneCoordinator<MainRoute, …>`；条件性的第二个 conformance 无法编译 |
| 2026-04-24 | 所有新增 engine 方法都使用 `request { local } remote: { RPC }` | 否则远程（XPC / directTCP）源会读到本地进程数据 |
| 2026-04-24 | `isImageIndexed` = 仅 "成功解析" | 避免对每个 factory 缓存项做 Result 包装；失败路径会重试 |
| 2026-04-24 | `DocumentState.runtimeEngine` 视为不可变 | Coordinator 在 init 时一次性捕获 engine；重新赋值不在范围 |
| 2026-04-24 | 包含失败的已完成批次保留至被清除 | 保留可操作的失败信息；驱动 toolbar `hasFailures` 状态 |
| 2026-04-24 | 状态 → Accepted | Review 决策已落实；plan 重新生成以匹配 |
| 2026-04-26 | `Open Settings` 不经 `MainRoute`,ViewController 直接调 `SettingsWindowController.shared.showWindow(nil)` | `MainRoute` 没有 `openSettings` case;与 `MCPStatusPopoverViewController` 现成模式一致 |
| 2026-04-26 | `RuntimeBackgroundIndexingCoordinator` 整体 `@MainActor` | `DocumentState` 是 `@MainActor`,coordinator init 跨 actor 读 `runtimeEngine` 在 Swift 6 严格并发下报错;统一标注后简化所有事件归约路径 |
| 2026-04-26 | `BackgroundIndexingEngineRepresenting` 仅 `: Sendable`(去掉 `AnyObject`) | 协议无任何方法需要引用语义;去掉 `AnyObject` 避免 actor conformance 的边角依赖 |
| 2026-04-26 | Manager 通过 `BackgroundIndexingEngineRepresenting` 协议消费 engine,不直接依赖 `RuntimeEngine` 类型 | manager 单元测试无需构造真实 engine(用 `MockBackgroundIndexingEngine` / `InstrumentedEngine`);避免 actor↔actor 之间的 `unowned` 反向引用;Plan Task 5 先于 Task 6,协议先于实现 |
