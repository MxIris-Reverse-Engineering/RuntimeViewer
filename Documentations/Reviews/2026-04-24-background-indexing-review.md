# Background Indexing Evolution & Plan — 审查闭环记录

审查对象:
- [0002-background-indexing.md](../Evolution/0002-background-indexing.md)(原 `Plans/2026-04-24-background-indexing-design.md`,已挪至 Evolution 并改成演进文档格式)
- [2026-04-24-background-indexing-plan.md](../Plans/2026-04-24-background-indexing-plan.md)

本文件现为闭环记录:列出审查中发现的问题,并标注每项是否已在 evolution 0002 / plan 中落实。

---

## 已决议并落地

| 决议 | 落地位置 |
|------|---------|
| Settings 变化订阅 → `@Observable` + `withObservationTracking` 重注册模式 | Plan Task 17;Evolution Scenario E / Alternative A |
| `BackgroundIndexingPopoverRoute` 合并进 `MainRoute`,ViewModel 为 `ViewModel<MainRoute>` | Plan Task 18 / Task 21;Evolution Alternative B / Components |
| 远程 source 支持 → 所有 engine 新方法按 `request { 本地 } remote: { RPC }` 模式实现,server dispatcher 挂对应 handler | Plan Task 3 / Task 4 / Task 4.5;Evolution "Remote Dispatch Model" |

---

## Critical — 已全部落地

### C1. `Semaphore` 不是 `RuntimeViewerCore` 的直接依赖 — ✅ 已修

`Package.swift:163` 里 `Semaphore` 只挂在 `RuntimeViewerCommunication` target 下。Plan 的 `RuntimeBackgroundIndexingManager.swift` 里 `import Semaphore` 会找不到 module(尤其一旦启用 `.memberImportVisibility`)。

**落地**:新增 **Plan Task 0**,在 `RuntimeViewerCore` target dependencies 追加 `.product(name: "Semaphore", package: "Semaphore")`。

---

### C2. `section(for:)` 的签名和 Plan 假设不一致 — ✅ 已修

真实签名(`RuntimeObjCSection.swift:704`、`RuntimeSwiftSection.swift:802`)是 `async throws -> (isExisted: Bool, section: ...)`。

**落地**:**Plan Task 4 Step 4** 的 `loadImageForBackgroundIndexing` 本地实现改成 `try await` 两个 factory 调用,与 `RuntimeEngine.swift:485-495` 一致。

---

### C3. `engine.imageLoadedSignal` 不存在 — ✅ 已修

`RuntimeEngine` 只暴露 `reloadDataPublisher: some Publisher<Void, Never>` 和 `imageNodesPublisher`,没有带 path 的 publisher。

**落地**:新增 **Plan Task 4.5**(`imageDidLoadPublisher`),在 `RuntimeEngine` 新增 `imageDidLoadSubject: PassthroughSubject<String, Never>`;本地 `loadImage(at:)` 成功后 emit;新增 `.imageDidLoad` CommandName 让远程 dispatcher 也可以 forward。**Plan Task 16** 订阅该 publisher。

---

### C4. 值类型 `Hashable` 声明不一致 — ✅ 已修

`BackgroundIndexingNode: Hashable` 要求关联值也是 `Hashable`。

**落地**:**Plan Task 1** 改标题为 "Create Sendable + Hashable value types ...",所有 `RuntimeIndexingBatchID` / `RuntimeIndexingBatchReason` / `RuntimeIndexingTaskState` / `RuntimeIndexingTaskItem` / `RuntimeIndexingBatch` / `RuntimeIndexingEvent` 统一加 `Hashable`;新增 `ResolvedDependency.swift` 文件。

---

## Significant — 已拍板

### S1. Factory 缓存只在解析成功时写入;失败路径语义未定 — ✅ 已拍板(方案 B)

**决议**:采用 **方案 B** —— `isImageIndexed` 语义定为"成功解析过",失败 path 下一个 batch 重试。

**落地**:Evolution 0002 "Terminology: Loaded vs. Indexed" 明确 "Failure to parse does **not** count as indexed";"Error Handling" 小节和 "Alternative D" 展开理由。Plan Task 3 `hasCachedSection(for:)` 保持 `sections[path] != nil` 语义无需改动 factory 内部。

---

### S2. `DocumentState.runtimeEngine` 是 `@Observed`,可被重新赋值 — ✅ 已拍板(方案 a)

**决议**:采用 **方案 a** —— 约定 `runtimeEngine` 在 Document 生命周期内不变。

**落地**:Evolution 0002 "Assumptions" 1 写明;**Plan Task 22 Step 1** 在 `DocumentState.swift` 现有 `@Observed public var runtimeEngine` 声明上补 doc comment 重申不可重赋。

---

## Moderate — 已全部落地

### M1. 路由案例名不一致 — ✅ 已修

**落地**:**Plan Task 21** 改为 "Register the toolbar item and add the `MainRoute.backgroundIndexing` case",新增 case 命名为 `backgroundIndexing(sender:)`(不带 Popover 后缀),与现有 `mcpStatus(sender:)` 对齐。

---

### M2. `actor` 内 `lazy var` 的指引不准 — ✅ 已修

**落地**:**Plan Task 11 Step 2** 改成显式存储属性 + init 末尾赋值:

```swift
public private(set) var backgroundIndexingManager: RuntimeBackgroundIndexingManager!
// ...
self.backgroundIndexingManager = RuntimeBackgroundIndexingManager(engine: self)
```

`lazy` 分支已删除。

---

### M3. `objcSectionFactory` / `swiftSectionFactory` 当前是 `private` — ✅ 已修

**落地**:**Plan Task 3 Step 4** 标记为 "must-do",把两个 factory 的访问级别从 `private` 改为 `internal`,以便 `RuntimeEngine+BackgroundIndexing.swift` 的 extension 访问。

---

### M4. `DependType.weakLoad` 实际遇不到 — ✅ 已修

**落地**:Evolution 0002 "Dependency type filter" 明确写 "Included: `.load`, `.reexport`, `.upwardLoad`;`.lazyLoad` skipped。`LC_LOAD_WEAK_DYLIB` 被 MachOKit 解码为 `.load`(见 `MachOImage.swift:168-173`)"。

---

### M5. BFS 容器在设计文档和 plan 之间漂移 — ✅ 已修

**落地**:Evolution 0002 "Dependency Graph Expansion" 改为 `Array + removeFirst()`,并说明 `Array.removeFirst()` 对 depth ≤ 5 足够。与 Plan Task 7 对齐。

---

## Minor — 已全部落地

### m1. Task 17 是空 checklist — ✅ 已修

**落地**:原 Task 17("Expose prioritize entry point for sidebar selection")整段删除。编号重排后 Task 17 现在是 "React to Settings changes via `withObservationTracking`"。

---

### m2. `test_mainExecutablePath_returnsNonEmptyPath` 注释缺失 — ✅ 已修

**落地**:**Plan Task 4 Step 2** 在测试函数上方补注释说明在 XCTest context 下该方法返回 test runner 的路径,这恰好验证"返回 dyld image 0"契约。

---

### m3. Popover outline view `child(_:ofItem:)` defensive 分支 — ✅ 已修

**落地**:**Plan Task 19 Step 1** 的 `NSOutlineViewDataSource.child(_:ofItem:)` failure 分支改成 `preconditionFailure("unexpected outline item type: \(type(of: item))")`。

---

### m4. `mutating(_:_:)` 全局函数污染模块 — ✅ 已修

**落地**:**Plan Task 14** 把 `mutating<T>` helper 从文件末尾的全局函数挪到 `RuntimeBackgroundIndexingCoordinator` class 的 private method(在 `apply(event:)` 下方)。

---

### m5. 优先级测试靠 sleep 控制顺序,易 flake — ✅ 已修

**落地**:**Plan Task 10 Step 1** 将 `test_prioritize_movesPendingItemAhead` 重写为 `test_prioritize_emitsTaskPrioritizedEvent`,通过断言 `.taskPrioritized` 事件序列来验证,不依赖 `Task.sleep` 时序。

---

## Review 自己遗漏的问题(新增 N1–N6)

下列问题在初稿 review 中未捕捉,已在本轮更新时落到 evolution / plan。

### N1. Popover ViewModel 的 `isEnabled` 只在 `transform` 里读一次

原 plan Task 19(现 Task 18)写 `isEnabled = Settings.shared.backgroundIndexing.isEnabled`,后续 Settings 切换 toggle 时不刷新,popover 的 empty state 卡死。

**落地**:**Plan Task 18 Step 2** 新增 `subscribeToIsEnabled()` 方法,用同样的 `withObservationTracking` re-register 模式同步 `isEnabled`。`init` 里 seed 初值。

---

### N2. Coordinator 一次性捕获 `runtimeEngine` 与 S2 联动

Coordinator `init` 里 `self.engine = documentState.runtimeEngine` 一次性捕获,配合 `@Observed` 的 `runtimeEngine` 可以被重新赋值,会出现持有旧 engine 的 bug。

**落地**:与 S2 合并处理 —— Evolution Assumptions 与 Plan Task 22 Step 1 的 doc comment 统一约束。

---

### N3. MockEngine / InstrumentedEngine 缺 `@unchecked Sendable`

协议声明 `AnyObject, Sendable`,但 `MockBackgroundIndexingEngine` / `InstrumentedEngine` 以 `NSLock + var` 守同步,Swift 6 concurrency checker 下会报非 Sendable。

**落地**:**Plan Task 5 Step 3** 给 `MockBackgroundIndexingEngine` 加 `@unchecked Sendable`;**Task 8 Step 1** 的 `InstrumentedEngine` 同样加 `@unchecked Sendable`。`ConcurrencyCounter` 原本已有。

---

### N4. `mainExecutablePath` 本地实现与 design dyld index 0 的契约

原 plan Task 4 Step 3 用 `DyldUtilities.imageNames().first ?? ""`;dyld 合约是 image 0 就是主执行体,但没在 plan 里明确。远程分支更需要分发。

**落地**:**Plan Task 4 Step 4** 本地分支加注释 `// dyld guarantees image index 0 is the main executable.`;远程走 `request { local } remote: { RPC }` 分发,具体按 R3 决议落实(新增 `.mainExecutablePath` CommandName)。

---

### N5. Task 10 prioritize 测试断言本身依赖实现细节

原断言基于 load 顺序和 `maxConcurrency=1` 的假设,加 sleep 导致更容易 flake。

**落地**:与 m5 合并 —— **Plan Task 10 Step 1** 断言改为事件序列(不依赖时序的等价条件),具体是 `.taskPrioritized` 事件序列。

---

### N6. `.batchFinished` 立刻从 UI 移除,失败批次无处可见

原 plan Task 25(现 Task 24)的 reducer `batches.removeAll { $0.id == finished.id }` 在 `.batchFinished` 也直接删,含 `.failed` 子项的批次随之消失,toolbar 的 `.hasFailures` 永远不会亮。

**落地**:**Plan Task 24** 重写为 "Retain failed batches; refresh image list once per batch finish",`.batchFinished` 含失败子项则保留 batch,直到用户按 Popover 的 `Clear Failed` 触发 `clearFailedBatches()`。Evolution 0002 Alternative E 解释此权衡。

---

## 收尾状态

- **Evolution 0002** 已生效,替代原 `Plans/2026-04-24-background-indexing-design.md`(文件已删除)。
- **Plan** 按 review 全部建议更新,Tasks 重编号为 0 / 1–4 / 4.5 / 5–26,并补 "Why" 说明段落。
- **本 review** 不再存在 open issue,保留作为历史闭环记录。

新发现的问题请新开一轮 review 记录,不要追加到本文件。
