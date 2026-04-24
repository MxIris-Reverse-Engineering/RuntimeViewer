# Background Indexing Design & Plan — 审查遗留问题

审查对象:
- [2026-04-24-background-indexing-design.md](../Plans/2026-04-24-background-indexing-design.md)
- [2026-04-24-background-indexing-plan.md](../Plans/2026-04-24-background-indexing-plan.md)

本文件只记录尚未闭环的问题。已在对话中确定方案、不再单独跟踪的决策:
- Settings 变化订阅 → 改用 `@Observable` + `withObservationTracking` 重注册模式
- `BackgroundIndexingPopoverRoute` 合并进 `MainRoute`(ViewModel 改成 `ViewModel<MainRoute>`)
- 远程 source 支持 → 所有 engine 新方法按 `request { 本地 } remote: { RPC }` 模式实现,server dispatcher 挂对应 handler

---

## Critical — 不修会直接编译失败或运行出错

### C1. `Semaphore` 不是 `RuntimeViewerCore` 的直接依赖

`Package.swift` 里 `Semaphore` 只挂在 `RuntimeViewerCommunication` target 下。Plan 的 `RuntimeBackgroundIndexingManager.swift` 里 `import Semaphore` 会找不到 module。

**修复**:在 `RuntimeViewerCore/Package.swift` 的 `RuntimeViewerCore` target dependencies 追加:
```swift
.product(name: "Semaphore", package: "Semaphore")
```

Plan 需新增 Task 0 专做此事。

---

### C2. `section(for:)` 的签名和 Plan 假设不一致

真实签名(`RuntimeObjCSection.swift:704`、`RuntimeSwiftSection.swift:802`):
```swift
func section(for imagePath: String, progressContinuation: ...) async throws
    -> (isExisted: Bool, section: RuntimeObjCSection)
```

Plan 里 `loadImageForBackgroundIndexing` 漏了 `try await`:
```swift
_ = objcSectionFactory.section(for: path)
_ = swiftSectionFactory.section(for: path)
```

**修复**:与 `RuntimeEngine.loadImage(at:)`(`RuntimeEngine.swift:485-495`)一致:
```swift
_ = try await objcSectionFactory.section(for: path)
_ = try await swiftSectionFactory.section(for: path)
```

---

### C3. `engine.imageLoadedSignal` 不存在

Plan Task 16 Step 2 订阅 `engine.imageLoadedSignal`,但 `RuntimeEngine` 只暴露 `reloadDataPublisher: some Publisher<Void, Never>`(无 path 载荷)和 `imageNodesPublisher`(全量列表)。

**修复**:在 `RuntimeEngine` 新增一个带 path 的 publisher,`loadImage(at:)` 的本地分支和远程 dispatcher 对应 handler 都要 emit:
```swift
private nonisolated let imageDidLoadSubject = PassthroughSubject<String, Never>()
public nonisolated var imageDidLoadPublisher: some Publisher<String, Never> {
    imageDidLoadSubject.eraseToAnyPublisher()
}
```
`loadImage(at:)` 成功后 `imageDidLoadSubject.send(path)`。Plan Task 16 订阅该 publisher。

---

### C4. 值类型 `Hashable` 声明不一致

Plan Task 19 声明 `BackgroundIndexingNode: Hashable`,但其关联值 `RuntimeIndexingBatch` / `RuntimeIndexingTaskItem` / `RuntimeIndexingBatchReason` / `RuntimeIndexingTaskState` / `RuntimeIndexingBatchID` / `ResolvedDependency` 只有 `Sendable, Identifiable, Equatable`。

**修复**:Task 1 所有值类型统一加 `Hashable`:
```swift
public struct RuntimeIndexingBatchID: Hashable, Sendable { ... }
public enum RuntimeIndexingBatchReason: Sendable, Hashable { ... }
public enum RuntimeIndexingTaskState: Sendable, Hashable { ... }
public struct RuntimeIndexingTaskItem: Sendable, Identifiable, Hashable { ... }
public struct RuntimeIndexingBatch: Sendable, Identifiable, Hashable { ... }
public struct ResolvedDependency: Codable, Sendable, Hashable { ... }
```

---

## Significant — 需要拍板的语义/假设

### S1. Factory 缓存只在解析成功时写入;失败路径语义未定

`RuntimeObjCSection.swift:710-713`:
```swift
let section = try await RuntimeObjCSection(...)
sections[imagePath] = section  // throw 时不写缓存
```

所以 `hasCachedSection(path) = (sections[path] != nil)` 实际等价于"解析成功过"。失败 path 下一个 batch 会重试。

设计文档写了"cache empty / nil results as well — the cache key's presence becomes the 'attempted' bit",但 plan 悬空。二选一:

- **方案 A**(对齐设计文档):给 factory 加 `attemptedFailures: Set<String>` 或把缓存值改成 `Result<Section, Error>`,`isImageIndexed` 包含失败路径。
- **方案 B**(简化):`isImageIndexed` 语义定为"成功解析过",设计 + 测试文档明确"失败 path 每次重试"。

---

### S2. `DocumentState.runtimeEngine` 是 `@Observed`,可被重新赋值

`DocumentState.swift`:
```swift
@Observed public var runtimeEngine: RuntimeEngine = .local
```

Coordinator init 时的 `let engine = documentState.runtimeEngine` 只做一次性捕获。如果 Document 生命周期内切换 local/remote,Coordinator 持有旧 actor,batch 发到错的进程。

**修复**(择一):
- (a) 文档里明确约定:`runtimeEngine` 在 Document 生命周期内不变 —— 写进设计文档 Assumptions。
- (b) Coordinator 订阅 `documentState.$runtimeEngine`,切换时 `cancelAllBatches` 并重绑。

推荐 (a)。

---

## Moderate — 名字/结构错位,机械修复但别漏

### M1. 路由案例名不一致

`MainRoute.swift:18` 实际是 `case mcpStatus(sender: NSView)`,不是 `mcpStatusPopover`。

**修复**:
- Plan Task 22 文案 `next to mcpStatusPopover` → `next to mcpStatus`。
- 新增 case 按现有风格命名为 `backgroundIndexing(sender:)`,不带 Popover 后缀。

---

### M2. `actor` 内 `lazy var` 的指引不准

Plan Task 11 把 `lazy var backgroundIndexingManager` 作为主方案。actor 的 `lazy` 初始化触发点走 actor 隔离,实践里不自然。

**修复**:主方案改为显式存储 + init 末尾赋值,删 `lazy` 分支:
```swift
public private(set) var backgroundIndexingManager: RuntimeBackgroundIndexingManager!

// init 末尾
self.backgroundIndexingManager = RuntimeBackgroundIndexingManager(engine: self)
```

---

### M3. `objcSectionFactory` / `swiftSectionFactory` 当前是 `private`

`RuntimeEngine.swift:147-149`:
```swift
private let objcSectionFactory: RuntimeObjCSectionFactory
private let swiftSectionFactory: RuntimeSwiftSectionFactory
```

Plan 的 `RuntimeEngine+BackgroundIndexing.swift` 在 extension 里访问两者 —— extension 不能访问 private(除非同文件)。

**修复**:Task 3 里把"如果是 private 再改"改成**必做**:提升到 `internal`,或把 extension 方法写进主文件。

---

### M4. `DependType.weakLoad` 实际遇不到

MachOKit 的 `MachOImage.swift:174-180` 把 `.loadWeakDylib` 归并到 `.load`,`.weakLoad` case 只在 DependType 定义里声明。

**修复**:设计文档 Dependency type filter 一节改成:
> Included: `.load`, `.reexport`, `.upwardLoad`(注:weak-linked dylib 在 MachOKit 里也解析为 `.load`)
> Skipped: `.lazyLoad`

---

### M5. BFS 容器在设计文档和 plan 之间漂移

设计文档写 `Deque<(path, level)>`,Plan 用 `Array + removeFirst()`。深度 ≤5 不影响正确性。

**修复**(择一):把设计文档改成 Array,或把 Plan 回退到 Deque —— 保持一致。

---

## Minor — 清理项

### m1. Task 17 是空 checklist

Plan Task 17 明确写"Skip — the placeholder is intentional"。执行 plan 时会疑惑。

**修复**:删 Task 17,或把"prioritize API 已存在"验证合进 Task 24 Step 1。

---

### m2. `test_mainExecutablePath_returnsNonEmptyPath` 注释缺失

该测试拿到的是 XCTest runner 的路径,不是 RuntimeViewer.app。断言本身没错,但执行者会误解。

**修复**:加一行注释说明 `mainExecutablePath()` 在测试里返回 XCTest runner 路径,这恰好验证"返回 dyld image 0"契约。

---

### m3. Popover outline view `child(_:ofItem:)` defensive 分支

Plan Task 20 失败分支构造了一个空 `RuntimeIndexingBatch` 返回,会掩盖逻辑错误。

**修复**:换成 `preconditionFailure("unexpected outline item type")`。

---

### m4. `mutating(_:_:)` 全局函数污染模块

Plan Task 14 把 `mutating<T>` helper 放在 `RuntimeBackgroundIndexingCoordinator.swift` 末尾作为全局函数。

**修复**:挪到 Coordinator 的 `private` extension,或加 `private` file-scope。

---

### m5. 优先级测试靠 sleep 控制顺序,易 flake

Plan Task 10 `test_prioritize_movesPendingItemAhead` 用 `Task.sleep(15_000_000)` / `30_000_000` 控制 ordering,CI 卡顿会 flake。

**修复**(择一):
- 给 MockEngine 加"手动步进"机制(`continuation` 闸门),测试确定性控制每一步完成时机。
- 或把断言改为"`taskPrioritized` 事件被 emit 且 `priorityBoostPaths` 包含该 path"这种不依赖时序的等价条件。

---

## 修复顺序建议

改 plan 自身、再落 code:

1. **新增 Task 0**:C1(`Semaphore` 依赖)
2. **Task 1 改**:C4(`Hashable`);补 `ResolvedDependency` 类型
3. **Task 3 改**:C2(`try await`)、M3(`internal`)
4. **新增 Task 4.x**:C3(`imageDidLoadPublisher`)
5. **Task 11 改**:M2(去掉 `lazy var`)
6. **Task 17 改**:m1(删/合并)
7. **Task 20 改**:m3(`preconditionFailure`)
8. **Task 10 / 14 改**:m5(去 sleep)、m4(helper 挪位)

S1 / S2 需先拍板语义/假设再落 plan。
M1 / M4 / M5 / m2 是文档/注释一致性,对照改即可。
