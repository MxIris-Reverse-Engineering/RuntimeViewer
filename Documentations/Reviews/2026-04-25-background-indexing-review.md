# Background Indexing Evolution & Plan — 第二轮审查

审查对象:
- [0002-background-indexing.md](../Evolution/0002-background-indexing.md)
- [2026-04-24-background-indexing-plan.md](../Plans/2026-04-24-background-indexing-plan.md)

承接 [2026-04-24-background-indexing-review.md](2026-04-24-background-indexing-review.md) (该文件已闭环,本轮在新文件中开新一轮 issue)。

本轮针对 Evolution 0002 进入 Accepted 后的 Plan / Evolution 文档,做一次代码侧的对账核验。下列问题在上一轮 review 中没有被捕获,均通过查看实际仓库代码确认。

**状态**: O1–O8 已全部在本轮闭环时落地到 Plan / Evolution;无 open issue。

---

## 复核确认 (与第一轮 review 一致)

| 已落实条目 | 代码侧核验 |
|---|---|
| C1: `RuntimeViewerCore` 显式依赖 `Semaphore` | `RuntimeViewerCore/Package.swift:163` 当前 Semaphore 仅挂在 `RuntimeViewerCommunication` target;Plan Task 0 修复正确 |
| C2: `section(for:)` 真实签名 | `RuntimeObjCSection.swift:704` / `RuntimeSwiftSection.swift:802` 均为 `async throws -> (isExisted: Bool, section: ...)`,Plan Task 4 Step 4 已对齐 |
| C3: 缺 per-path publisher | `RuntimeEngine.swift:135/139` 当前只有 `imageNodesPublisher` / `reloadDataPublisher`,Plan Task 4.5 新增方向正确 |
| C4: 值类型 `Hashable` 全套 | Plan Task 1 字段齐全 |
| M3: factory 当前 `private` | `RuntimeEngine.swift:147/149` 确认 `private let`,Plan Task 3 Step 4 提到 internal 正确 |
| M4: `LC_LOAD_WEAK_DYLIB` 折叠为 `.load` | `MachOKit/Sources/MachOKit/MachOImage.swift:168-173` 的 `loadWeakDylib` 分支显式构造 `type: .load`,Evolution 引用正确 |
| Settings `@Observable` | `RuntimeViewerSettings/Settings.swift:6-9` 已是 `@Observable`,`withObservationTracking` 路线可行 |

---

## Critical — 阻塞实现 — ✅ 已落地

### O1. `RuntimeEngine.request<T>` 是 `private`,跨文件 extension 调不到 — ✅ 已修

`RuntimeEngine.swift:468`:

```swift
private func request<T>(local: () async throws -> T,
                        remote: (_ senderConnection: RuntimeConnection) async throws -> T)
    async throws -> T { ... }
```

Plan Task 3 / 4 / 4.5 把所有新 API 写在**新增的另一文件** `RuntimeEngine+BackgroundIndexing.swift` 里,例如:

```swift
// RuntimeEngine+BackgroundIndexing.swift  (Plan Task 3 Step 6)
extension RuntimeEngine {
    public func isImageIndexed(path: String) async throws -> Bool {
        try await request {                 // <-- private,跨文件不可见
            objcSectionFactory.hasCachedSection(for: path)
                && swiftSectionFactory.hasCachedSection(for: path)
        } remote: { ... }
    }
}
```

Swift 中 `private` 允许同一类型在**同一文件**内的 extension 共享 private 成员;`RuntimeEngine.swift` 与 `RuntimeEngine+BackgroundIndexing.swift` 是不同文件,private 在该边界仍不可见。后果是 Plan Task 3、Task 4、Task 4.5 内引用 `request { ... } remote: { ... }` 全部编不过。

**建议修复**: 在 Plan Task 3 Step 4 旁新增一步,把 `RuntimeEngine.swift:468` 的 `private` 提至 `internal`(与同步骤把两个 factory 提到 internal 的做法一致),或把 `+BackgroundIndexing.swift` 的 extension 内容直接放进 `RuntimeEngine.swift` 末尾 (后者牺牲文件组织、但不动访问级别)。Evolution 0002 "Remote Dispatch Model" 节也应补一句说明 `request` 已开放给 internal extension。

**落地**: Plan Task 3 Step 4 标题改为"放宽 factory 与 `request<T>` 分发原语的访问级别(必做)",把 `request<T>` 与两个 factory 一并提至 `internal`。Evolution 0002 "Remote Dispatch Model" 节补充说明跨文件 extension 与访问级别要求。

---

### O2. Plan Task 12 与 Evolution 0002 关于 `Settings.backgroundIndexing` 的 `didSet` 不一致 — ✅ 已修

Evolution 0002:467-471 写法 (正确):

```swift
@Default(BackgroundIndexing.default)
public var backgroundIndexing: BackgroundIndexing = .init() {
    didSet { scheduleAutoSave() }
}
```

Plan Task 12 Step 2 line 1776 写法:

```swift
@Default(BackgroundIndexing.default) public var backgroundIndexing: BackgroundIndexing
```

后者**没有** `didSet { scheduleAutoSave() }`。然而 `Settings.swift:14-37` 上现有所有字段 (`general`、`notifications`、`transformer`、`mcp`、`update`) 全都用 `didSet { scheduleAutoSave() }` 模式触发自动保存:

```swift
// Settings.swift:14-17 (representative)
@Default(General.default)
public var general: General = .init() {
    didSet { scheduleAutoSave() }
}
```

按 Plan Task 12 Step 2 实施后,toggle Background Indexing 开关、调整 depth / maxConcurrency 都不会自动写盘,重启即丢失。

**建议修复**: Plan Task 12 Step 2 对齐 Evolution 0002,把 `didSet { scheduleAutoSave() }` 加回去。

**落地**: Plan Task 12 Step 2 已加回 `= .init() { didSet { scheduleAutoSave() } }`,并补充说明镜像现有字段模式的必要性。

---

## Significant — ✅ 已落地

### O3. `BackgroundIndexingEngineRepresenting` 协议签名与 RuntimeEngine 实际方法 / Coordinator 调用三处错位 — ✅ 已修

四处对同一组方法的 `async` / `throws` 假设不一致:

| 出处 | 签名 |
|---|---|
| Plan Task 5 Step 1 protocol | `func mainExecutablePath() async -> String` (no throws) |
| Plan Task 5 Step 1 protocol | `func dependencies(for path: String) async -> [...]` (no throws) |
| Plan Task 4 Step 4 RuntimeEngine 实现 | `public func mainExecutablePath() async throws -> String` |
| Plan Task 5 Step 2 conformance 实现 | `func dependencies(for path: String) -> [...]` (同步,非 async) |
| Plan Task 15 Coordinator 调用 | `let root = await engine.mainExecutablePath()` (不带 `try`) |

要么 protocol 必须改为 `async throws`,要么 RuntimeEngine 端对这两个 API 提供一组 non-throwing wrapper。直接抄 Plan 任意一种实现都会编不过。

`mainExecutablePath` 远程分支会真实 throw (XPC / TCP 失败),所以 throws 版本更安全。

**建议修复**:
- Plan Task 5 Step 1 协议把这两个方法改为 `async throws`。
- Plan Task 5 Step 2 conformance 实现也改为 `async throws`,内部 `let main = try await mainExecutablePath()`。
- Plan Task 15 (`documentDidOpen`) 把 `let root = await engine.mainExecutablePath()` 改为 `let root = try? await engine.mainExecutablePath()`,失败时 `guard let root = root, !root.isEmpty else { return }`。
- Coordinator 其它调用点同样补 `try`。

**落地**: Plan Task 5 Step 1 协议中 `isImageIndexed` / `mainExecutablePath` / `rpaths` / `dependencies` 全部改为 `async throws`(`canOpenImage` 保留为纯 async 因为它仅本地检查)。Plan Task 5 Step 2 conformance 中 `dependencies` 改为 `async throws`,`canOpenImage` / `rpaths` 保留 sync(Swift 允许更弱实现满足 `async throws` 协议)。Plan Task 5 Step 3 mock 同样保留 sync / non-throwing 实现。Plan Task 6 placeholder 与 Plan Task 7 BFS 内部调用改为 `try? await`,把错误降级为"未索引"以便重试(与 Alt D 一致)。Plan Task 8 `InstrumentedEngine` 同步改 throws。Plan Task 15 `documentDidOpen` 改为 `try? await` 包裹 + `guard let root` 解包。

### O4. Protocol 暴露 `MachOImage` 触发 Swift 6 严格并发问题 — ✅ 已修

Plan Task 5 Step 1:

```swift
protocol BackgroundIndexingEngineRepresenting: AnyObject, Sendable {
    func machOImage(for path: String) async -> MachOImage?   // <-- 非 Sendable
    ...
}
```

`MachOImage: MachORepresentable` (`MachOKit/Sources/MachOKit/MachOImage.swift:26`) 是含 unsafe pointer (`UnsafePointer<mach_header>`) 的 struct,未 conform `Sendable`。Sendable 协议在跨 actor 边界返回该类型会触发严格并发错误。`RuntimeViewerCore/Package.swift:158-160` 已启用 `.internalImportsByDefault` + `.immutableWeakCaptures`,后续若再启用 `.memberImportVisibility` 或 Swift 6 严格模式 (Swift 5 mode 下亦会 warn),这处会爆。

实际上 manager 端 (Plan Task 6 之后) **没有**直接消费 `MachOImage` —— Task 7 BFS 只调用 `engine.machOImage(for:)` 来"确认是否能 open",这完全可以用 `Bool` 返回值替代;真正用 `MachOImage` 的只有 conformance 内部的 `dependencies(for:)` / `rpaths(for:)` 实现 (它们不暴露 image 出去)。

**建议修复**:
- Plan Task 5 Step 1 把 `func machOImage(for path: String) async -> MachOImage?` 改为 `func canOpenImage(at path: String) async -> Bool`。
- Plan Task 7 BFS 中 `if await engine.machOImage(for: path) == nil` 同步替换为 `if !(await engine.canOpenImage(at: path))`。
- Plan Task 5 Step 2 conformance 把 `MachOImage(name: path) != nil` 作为 `canOpenImage` 实现。

**落地**: Plan Task 5 Step 1 协议表面去掉 `MachOImage`,新增 `canOpenImage(at:) async -> Bool`,并在协议 doc comment 写明"不暴露 MachOImage"。Plan Task 5 Step 2 / Step 3 / Plan Task 7 / Plan Task 8 InstrumentedEngine 同步全部更新。Plan Task 7 BFS 中无法打开的非根 path 直接标 `.failed("cannot open MachOImage")` 并 `continue`,替代了原先的 dead-code if 分支。

### O5. Plan Task 18 `transform` 同步调用 `@MainActor` 方法 — ✅ 已修

```swift
// Plan Task 18 Step 2 中
func transform(_ input: Input) -> Output {
    ...
    subscribeToIsEnabled()    // 同一文件下方标 @MainActor
}

@MainActor
private func subscribeToIsEnabled() { ... }
```

`ViewModel<Route>` 基类未明示 `@MainActor` 隔离 (从 CLAUDE.md "Base class: All ViewModels inherit `ViewModel<Route>`" 看不出);若 `transform` 不在 main actor,Swift 6 严格并发会报 isolation 错。即便编译通过,`subscribeToIsEnabled` 内部直接读写 `self.isEnabled` 也需保证调用点已在主线程。

**建议修复**: Plan Task 18 Step 2 把 transform 内的同步调用改为:

```swift
Task { @MainActor [weak self] in
    self?.subscribeToIsEnabled()
}
```

或在 ViewModel 类型上显式 `@MainActor` 标注,与 coordinator 中 `subscribeToSettings` 已经写的 `Task { @MainActor [weak self] in ... }` 模式保持一致。

**落地**: Plan Task 18 Step 2 transform 内 `subscribeToIsEnabled()` 包入 `Task { @MainActor [weak self] in self?.subscribeToIsEnabled() }`。

---

## Minor — ✅ 已落地

### O6. Plan Task 16 占位名 `engine.imageLoadedSignal` 与 Task 4.5 引入的 `imageDidLoadPublisher` 不一致 — ✅ 已修

Plan Task 4.5 Step 2 已经引入:

```swift
public nonisolated var imageDidLoadPublisher: some Publisher<String, Never> { ... }
```

但 Plan Task 16 Step 2 代码示例仍写:

```swift
engine.imageLoadedSignal
    .emitOnNext { [weak self] path in ... }
```

虽然 Step 1 写"调整下面的订阅以匹配",但同一份 plan 内两节命名不一致会让执行者在 Step 2 真去搜不存在的 `imageLoadedSignal` 符号。

**建议修复**: Plan Task 16 Step 2 直接用 `engine.imageDidLoadPublisher`,通过 RxCombine 桥 (项目 CLAUDE.md 列出 `RxCombine` 已是依赖) 转 RxSwift 后 `.emitOnNext { ... }`,或直接 `Task { for await ... in publisher.values }` 风格。

**落地**: Plan Task 16 重写为"Combine `Publisher.values` 桥到 AsyncStream"模式 —— 与 coordinator 已有的 manager event pump (`Task { for await event in stream }`) 形态一致。Step 1 新增 `imageLoadedPumpTask: Task<Void, Never>?` 与 deinit 取消;Step 2 用 `for await path in self.engine.imageDidLoadPublisher.values` 消费,补 `handleImageLoaded` 内"manager dedups by rootImagePath + reason discriminant"的注释,移除原"如果 engine 仅暴露 AsyncSequence" 的备选分支(已无歧义)。

### O7. Plan Task 4.5 Step 4 测试中 `await` 冗余 — ✅ 已修

```swift
let cancellable = await engine.imageDidLoadPublisher.sink { ... }
```

Plan Task 4.5 Step 2 把 publisher 标为 `nonisolated var`,访问无需 `await`。Swift 6 会 warn `no 'async' operations occur in 'await' expression`。

**建议修复**: 去掉 `await`:

```swift
let cancellable = engine.imageDidLoadPublisher.sink { ... }
```

**落地**: Plan Task 4.5 Step 4 测试中 `await` 已删除,并补一条"Swift 6 会 warn 'no async operations occur'"的解释注释。

### O8. Plan Task 11 IUO 解释措辞偏题 — ✅ 已修

> IUO 的理由:actor 不能在 `init` 完成对其他存储属性的注册前把 `self` 交给 manager;而 manager 在 init 之后是只读的 …

实际上 `RuntimeEngine.init` 在最后一行构造 manager 时,`self` 的所有 stored property (`objcSectionFactory`、`swiftSectionFactory` 等,见 `RuntimeEngine.swift:178-179`) 都已经初始化完成,不存在"前向引用 self"问题。真正需要的是规避 actor `lazy var` 与 `nonisolated` accessor 的初始化路径冲突。措辞不影响实现,但解释偏题,后续读者照该理由设计自己的 actor 时会被误导。

**建议修复**: Plan Task 11 Step 2 的"IUO 的理由"段改写为:"actor 上的 `lazy var` 强制每次首次访问都通过 actor 隔离,与 `nonisolated` 访问器不兼容,且初始化时机不直观。改用 IUO + 在 init 末尾赋值,语义更明确。"

**落地**: Plan Task 11 Step 2 的"IUO 的理由"段已改写,纠正"前向引用 self"措辞,改为强调"初始化时机偏好"——`init` 末尾构造 manager 时所有 stored property 已就位,没有前向 self 问题;选 IUO 是为了把 manager 构造保留在线性叙事末尾,与普通 `let` 必须在声明处给初值相比更可读。

---

## 收尾状态

- 本轮 8 条问题与 [2026-04-24 review](2026-04-24-background-indexing-review.md) 不重叠,该文件保留为闭环记录。
- **O1–O8 全部已在本轮闭环时落地**到 Plan / Evolution,具体修改见各条目的"落地"段。
- 不再存在 open issue,本文件保留作为历史闭环记录。
- 下一轮新发现请在 `Documentations/Reviews/` 下另开一份记录,不要追加到本文件。
