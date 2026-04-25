# Background Indexing Evolution & Plan — 第三轮审查

审查对象:
- [0002-background-indexing.md](../Evolution/0002-background-indexing.md)
- [2026-04-24-background-indexing-plan.md](../Plans/2026-04-24-background-indexing-plan.md)

承接 [2026-04-24-background-indexing-review.md](2026-04-24-background-indexing-review.md) 与 [2026-04-25-background-indexing-review.md](2026-04-25-background-indexing-review.md)(均已闭环),本轮在新文件中开新一轮 issue。

本轮把 Plan / Evolution 当作"已 Accepted"的稳定文档,再次对仓库当前代码做核验,挖出前两轮没捕捉的 6 条问题(N1–N6)。

**状态**: N1–N6 已全部在本轮闭环时落地到 Plan / Evolution;无 open issue。

---

## Critical — 阻塞实现

### N1. `MainRoute.openSettings` case 实际不存在 — ✅ 已修

Evolution 0002 第 568 行与 Plan Task 18 Step 2 都写道:popover 的 "Open Settings" 按钮触发 `router.trigger(.openSettings)`,理由是"已有的 `MainRoute.openSettings` case"。

但 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainRoute.swift:10-21` 的实际枚举只有:

```swift
public enum MainRoute: Routable {
    case main(RuntimeEngine)
    case select(RuntimeObject)
    case sidebarBack
    case contentBack
    case generationOptions(sender: NSView)
    case loadFramework
    case attachToProcess
    case mcpStatus(sender: NSView)
    case dismiss
    case exportInterfaces
}
```

**没有 `openSettings`**,`router.trigger(.openSettings)` 直接编译失败。

代码侧的现成参照在 `MCPStatusPopoverViewController.swift:200-203`:

```swift
output.openSettings.emitOnNext {
    SettingsWindowController.shared.showWindow(nil)
}
.disposed(by: rx.disposeBag)
```

—— ViewController 的闭包**直接**调用 `SettingsWindowController.shared.showWindow(nil)`,**不**走 router。ViewModel 只负责把 input.openSettings 透传到 output.openSettings。

**落地**:与 MCP popover 完全对齐 ——
- Plan Task 18 Step 2 ViewModel 的 `Output` 增加 `openSettings: Signal<Void>`,`transform` 把 `input.openSettings` 透传(经一个 PublishRelay)而**不**调用 `router.trigger(.openSettings)`。
- Plan Task 19 Step 1 ViewController `setupBindings` 增加 `output.openSettings.emitOnNext { SettingsWindowController.shared.showWindow(nil) }` 绑定,顶部 `import` 段补 `RuntimeViewerSettingsUI` 以拿到 `SettingsWindowController`。
- Evolution 0002 "Components" 与 "Sendable 值类型" 对应段落同步修订:`openSettings` 走 ViewController 闭包,**不**经 MainRoute。
- Evolution 0002 "决策日志" 追加一行。

---

### N2. ViewModel `Input` 4 字段,ViewController 只填 3 字段 — ✅ 已修

Plan Task 18 Step 2(第 2380-2385 行)`Input` 声明:

```swift
struct Input {
    let cancelBatch: Signal<RuntimeIndexingBatchID>
    let cancelAll: Signal<Void>
    let clearFailed: Signal<Void>     // ← 4 项
    let openSettings: Signal<Void>
}
```

Plan Task 19 Step 1(第 2656-2660 行)ViewController 创建处:

```swift
let input = BackgroundIndexingPopoverViewModel.Input(
    cancelBatch: cancelBatchRelay.asSignal(),
    cancelAll: cancelAllRelay.asSignal(),
    openSettings: openSettingsRelay.asSignal()    // ← 缺 clearFailed
)
```

且 ViewController 完全没有声明 `clearFailedRelay` / `clearFailedButton`。但 Evolution 0002 第 521 行明确写"页脚 ... 包含 `Cancel All` 按钮 ... `Clear Failed` 按钮(仅当存在保留的失败批次时可见)以及 `Close` 按钮"。Task 24 又交付了 `coordinator.clearFailedBatches()` 公共方法,等待 Input 路径调用,接不上。

**落地**:Plan Task 19 Step 1 补齐:
- 顶部 Relay 段加 `private let clearFailedRelay = PublishRelay<Void>()`。
- View 段加 `private let clearFailedButton = NSButton().then { $0.bezelStyle = .accessoryBarAction; $0.title = "Clear Failed" }`。
- `setupLayout` 的 `buttonStack` 改为 `{ cancelAllButton; clearFailedButton; closeButton }`。
- `setupActions` 增加 `clearFailedButton.target / action`,新增 `@objc private func clearFailedClicked() { clearFailedRelay.accept(()) }`。
- `setupBindings` 的 `Input` 初始化补 `clearFailed: clearFailedRelay.asSignal()`。
- `setupBindings` 增加 `output.hasAnyFailure` 绑定 → `clearFailedButton.isHidden = !hasAnyFailure`。

Plan Task 18 Step 2 ViewModel 同步:
- 类内增加 `@Observed private(set) var hasAnyFailure: Bool = false`。
- `Output` 增加 `hasAnyFailure: Driver<Bool>`。
- `transform` 把 `coordinator.aggregateStateObservable.map { $0.hasAnyFailure }` 桥到 `hasAnyFailure` 属性。

---

### N3. `RuntimeBackgroundIndexingCoordinator` init 跨 actor 访问 `DocumentState` — ✅ 已修

`DocumentState.swift:6-7` 声明:

```swift
@MainActor
public final class DocumentState {
```

而 Plan Task 14 Step 2 的 coordinator init:

```swift
public init(documentState: DocumentState) {
    self.documentState = documentState
    self.engine = documentState.runtimeEngine     // ← @MainActor 隔离属性
    startEventPump()
}
```

`RuntimeBackgroundIndexingCoordinator` 类**没有** `@MainActor` 隔离;只有 `apply(event:)` / `handleSettingsChange` / `refreshAggregate` 等单方法被标。Swift 6 严格并发(以及 Swift 5 的 `complete` checking)下,`init` 同步读取 `documentState.runtimeEngine` 会报跨 actor isolation 错。

**落地**:Plan Task 14 Step 2 把整个 coordinator 类标 `@MainActor`(与 `DocumentState` 一致)。原本散布在 `apply(event:)` / `handleSettingsChange` / `refreshAggregate` / `subscribeToSettings` / `clearFailedBatches` 上的 `@MainActor` 全部删除(类标注涵盖所有方法)。`startEventPump` / `startImageLoadedPump` 内 `for await ... in stream` 自动在 main actor 上跑,`apply(event:)` / `handleImageLoaded(path:)` 直接同步调用即可,不再需要 `await MainActor.run { ... }` 包装(Plan Task 14 Step 2 / Task 16 Step 2 的事件泵代码同步简化)。

Evolution 0002 "Components" 段 `RuntimeBackgroundIndexingCoordinator` 子节补一行:"`@MainActor` 隔离类(与 `DocumentState` 一致),所有事件归约与 Settings 观察都在主线程"。

---

### N4. `protocol BackgroundIndexingEngineRepresenting: AnyObject, Sendable` 与 actor conformance — ✅ 已修

Plan Task 5 Step 1 把协议声明成 `AnyObject, Sendable`,Plan Task 5 Step 2 让 `extension RuntimeEngine: BackgroundIndexingEngineRepresenting`(`RuntimeEngine` 是 `actor`)。

actor 类型对 `AnyObject` 约束的 conformance 在 Swift 5.7+ 主线允许,但仍是相对边角的特性,**而且协议的所有方法都不要求引用语义**(没有 `unowned` / `weak` 持有的需求,manager 内是按值持有 `engine: any BackgroundIndexingEngineRepresenting`)。`AnyObject` 约束纯粹是历史习惯,在此并无作用,反而引入"actor conform AnyObject 是否合法"的认知负担。

**落地**:Plan Task 5 Step 1 协议改为只 `: Sendable`:

```swift
protocol BackgroundIndexingEngineRepresenting: Sendable {
    ...
}
```

Mock(`MockBackgroundIndexingEngine`)与 `InstrumentedEngine` 保持 `final class ... @unchecked Sendable`(它们本来就是 class,Sendable 协议要求由 `@unchecked` 满足),conformance 不变;`RuntimeEngine`(actor)conformance 也不变,但少了"actor + AnyObject" 的边角依赖。

---

## Significant — 表述/优化

### N5. Plan Task 18 Step 2 `transform` 中 `subscribeToIsEnabled` 的 `Task` 包裹是过度修正 — ✅ 已修

`open class ViewModel<Route: Routable>: NSObject` 类头带 `@MainActor`(`ViewModel.swift:9-10`),所以 `transform(_:)` 自动是 MainActor 隔离方法,直接同步调用 `subscribeToIsEnabled()` 完全合法。Plan 当前写法:

```swift
Task { @MainActor [weak self] in
    self?.subscribeToIsEnabled()
}
```

把"初始 isEnabled 订阅 + seed 同步初值"延后到下一次 main runloop 调度,popover 弹出瞬间的 isEnabled 仍是 stored 默认值 `false`,会出现一帧"已禁用"空状态闪烁(即便 Settings 中 isEnabled = true)。

第二轮 review O5 当时按"`transform` 不在 MainActor"假设修正,但 ViewModel 基类的 `@MainActor` 标注让该假设站不住脚。

**落地**:Plan Task 18 Step 2 `transform` 内 `Task { @MainActor [weak self] in self?.subscribeToIsEnabled() }` 改回同步直调:

```swift
subscribeToIsEnabled()
```

并补一条注释:"ViewModel 基类已是 `@MainActor`,直接同步调用即可,seed 初值同步比异步派发更适合 popover 第一帧"。

第二轮 review 文件 [2026-04-25-background-indexing-review.md](2026-04-25-background-indexing-review.md) 的 O5"落地"段会保留(历史闭环不动),但本轮 N5 视为对其的二次修正。

---

### N6. Evolution 0002 Assumption #2 表述不严谨 — ✅ 已修

Evolution 0002 第 601 行:

> 2. **`RuntimeBackgroundIndexingManager` 仅运行在引擎的宿主进程内。** 对于远程(XPC / directTCP)来源,*引擎方法*通过 `request { local } remote: { RPC }` 镜像,但 *manager* 存活在服务端引擎的 actor 中。UI 客户端只通过本地引擎引用消费 manager 状态。

但 Plan Task 11 在**所有** RuntimeEngine 实例(含远程引擎)init 末尾构造 manager,manager 实例**本地**活着。manager 触发的 `engine.loadImageForBackgroundIndexing(at:)` 等方法走 `request { local } remote: { RPC }` 分发到服务端,这才符合 Plan 的实际接线。Evolution 原话"manager 存活在服务端引擎的 actor 中"会让读者误以为远程 engine 不创建 manager。

**落地**:Evolution 0002 假设 #2 改写为:

> 2. **`RuntimeBackgroundIndexingManager` 与 engine 一对一构造,在客户端进程内活着。** 对于远程(XPC / directTCP)来源,manager 实例仍在客户端运行,但其内部调用的 engine 公共方法(`isImageIndexed` / `mainExecutablePath` / `loadImageForBackgroundIndexing` / `dependencies(for:)` 等)都走 `request { local } remote: { RPC }` 分发,真正的索引工作由服务端目标进程执行。UI 客户端通过本地引擎引用消费 manager 事件流。

---

## 收尾状态

- 本轮 6 条问题(N1–N6)与前两轮 review 不重叠,已全部在本轮闭环时落地到 Plan / Evolution,具体修改见各条目"落地"段。
- 不再存在 open issue,本文件保留作为历史闭环记录。
- 下一轮新发现请在 `Documentations/Reviews/` 下另开一份记录,不要追加到本文件。
