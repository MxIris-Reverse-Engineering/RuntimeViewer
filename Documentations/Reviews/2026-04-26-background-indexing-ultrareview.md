# Background Indexing UltraReview 审查发现

审查对象:
- 分支 `feature/runtime-background-indexing` → `main`
- 范围:46 files changed, 4710 insertions(+), 1408 deletions(-)
- 工具:`/ultrareview` 云端多 Agent 审查

承接 [2026-04-26 implementation-review](2026-04-26-background-indexing-implementation-review.md) 的内部审查,本轮由独立 Agent 重新走一遍代码,产出 8 条发现。其中部分与内部 review 的 I 项条目重叠(I1 / I3 / I5),作为独立佐证;另外补出 4 条新问题。

**判定**: 没有阻塞 merge 的 Critical 项;有 4 条 Normal 与 3 条 Nit + 1 条 pre-existing 跟进项。

---

## Normal

### N1. `RuntimeEngine` ↔ `RuntimeBackgroundIndexingManager` 循环引用导致每个远程 engine 泄漏

**文件**: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift:4-16`

`RuntimeEngine.swift:186` 强持 `backgroundIndexingManager: RuntimeBackgroundIndexingManager!`,manager 又通过 `private let engine: any BackgroundIndexingEngineRepresenting` 强持 engine。

Evolution 0002 决议 N4 主动把协议从 `AnyObject, Sendable` 改成纯 `Sendable`,理由是"manager 按值持有 engine,无引用语义需求"。**这个理由是错的**:`any P` 装箱 actor / class 仍然是强引用,移除 `AnyObject` 只是失去了把 existential 标 `weak`/`unowned` 的可能性,并没有让它变成值语义。

`RuntimeEngine.local` 是单例,泄漏一次性。但以下路径每次都 `new RuntimeEngine`:
- `RuntimeViewerUsingAppKit/.../RuntimeEngineManager.swift:168, 269, 290`(attached / Catalyst client / 通用工厂)
- `RuntimeViewerServer/.../RuntimeViewerServer.swift:59, 62, 77`(server 端每连接一对 engine+manager)
- `RuntimeViewerUsingUIKit/.../AppDelegate.swift:23`(Bonjour server engine)

`RuntimeEngineManager.terminateRuntimeEngine` 把 engine 从 tracking 数组移除时,环让 engine + manager + AsyncStream continuation + activeBatches + driving Task + 两个 SectionFactory 缓存全部留下,跨用户切换 source / 多次 attach-detach 累计增长无界。

`RuntimeBackgroundIndexingManager.deinit` 只 `continuation.finish()`,不能解环 —— 实际上因为环存在 deinit 永远不会被调用。

**修法**:回退 N4 决议,把协议恢复为 `AnyObject, Sendable`,manager 持有改为 `private weak var engine: (any BackgroundIndexingEngineRepresenting)?`(或 `unowned` 如果文档约定 engine 寿命包住 manager)。所有 callsite `try await engine?.…`,nil 时直接 bail。约 3 行核心改动 + doc comment 修正。

### N2. Coordinator 跨 source 切换捕获过时 `RuntimeEngine`

**文件**: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift:40-48`

(对应 implementation-review 的 I3,这里再次确认问题确实未在 PR 中修。)

`init` 一次性快照 `documentState.runtimeEngine` 到 `self.engine`,所有方法(`cancelBatch` / `cancelAllBatches` / `prioritize` / `startEventPump` / `startImageLoadedPump` / `documentDidOpen` / `handleImageLoaded` / `handleSettingsChange`)都闭包 `self.engine`。

`MainCoordinator.swift:33-34` 在 `.main(let runtimeEngine)` 时 `documentState.runtimeEngine = runtimeEngine`,`backgroundIndexingCoordinator` 是 `lazy var`,不会重建。

复现:

1. 启动时 `Document.makeWindowControllers` 触发首次访问 → coordinator 构造,捕获 `engine = .local`。
2. 用户在 toolbar PopUp 切到 Bonjour/XPC 远程 → `MainCoordinator.prepareTransition` 改写 `documentState.runtimeEngine`,但 `documentState.backgroundIndexingCoordinator` 仍是同一实例。
3. `MainWindowController.setupBindings` 重新绑定 toolbar 到 `coordinator.aggregateStateObservable`,但该 relay 由旧的 `.local` manager 驱动 → toolbar 永远空闲。
4. 新 engine 的 `backgroundIndexingManager` 没人订阅,主可执行文件永远不被索引。
5. `SidebarRootViewModel` 的 `prioritize(...)` 全部路由到死 manager,静默 no-op。

`DocumentState.runtimeEngine` 的 doc comment 警告"不要重新赋值",但 `MainCoordinator` 在每次 source 切换都违反这个约定。

**修法**(两选一):
- (a) 在 `DocumentState` 暴露 `recreateBackgroundIndexingCoordinator()`,`MainCoordinator.prepareTransition` `.main` 分支 reassign 之后调用,旧 coordinator 取消 pump、新 coordinator 接管。约 15 行。
- (b) 让 coordinator 订阅 `documentState.$runtimeEngine`,变更时取消 pump、swap `self.engine`、重启 pump。改动更深但保留失败批次 state。

推荐 (a),与"每个 Document/engine 对一个 coordinator"心智模型一致。

### N3. Manager batch dedup 注释/spec 都说有,代码中没实现

**文件**: `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift:51-73`

(对应 implementation-review 的 I1,独立验证。)

`RuntimeBackgroundIndexingCoordinator.swift:236-247` `handleImageLoaded` 注释:
```swift
// Avoid double-starting if the path is the main executable being opened
// at app launch — documentDidOpen already dispatched that batch. Manager
// dedups batches that share rootImagePath + reason discriminant, so a
// second call here is a no-op rather than a wasted batch.
```

Evolution 0002 第 626 行:*"manager 去重:如果某活动批次的 `rootImagePath == root` 且 `reason` 的判别式匹配,返回其已有 `RuntimeIndexingBatchID`。"*

`RuntimeBackgroundIndexingManager.startBatch` 实际:每次都 `RuntimeIndexingBatchID()` + `activeBatches[id] = state`,无任何扫描。

**额外发现**:即使 spec 描述的 dedup 实现了,最现实的双批次场景也抓不到 —— `documentDidOpen` 派发 `.appLaunch`、之后 `imageDidLoadPublisher` 对同一 path 触发 `.imageLoaded(path:)`,**两个 reason 的判别式不同**,spec 的去重规则也太窄。

**修法**:
- 实现 dedup,扫 `activeBatches.values` 找 `!isFinished && rootImagePath == root && (reason 判别式相同 OR 同根扩展规则)`,命中则返回旧 ID。约 10 行。
- 把规则放宽为"任意匹配 `rootImagePath`",抓住 `.appLaunch` ↔ `.imageLoaded` 这一对。
- 否则**至少删掉 coordinator 的误导注释**,不要让未来维护者以为有保护。

### N4. `DylibPathResolver` 拒绝所有 dyld-shared-cache 系统 framework

**文件**: `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DylibPathResolver.swift:36-41`

绝对路径分支末尾:
```swift
return fileManager.fileExists(atPath: installName) ? installName : nil
```

Apple Silicon 上 `/usr/lib/libobjc.A.dylib`、`/usr/lib/libSystem.B.dylib`、`/System/Library/Frameworks/Foundation.framework/Foundation`、`/System/Library/Frameworks/UIKit.framework/UIKit` 等**只存在于 dyld shared cache,无磁盘文件**,`fileExists` 返回 false,resolver 返回 nil。

`expandDependencyGraph`(RuntimeBackgroundIndexingManager.swift:117-123)对 nil `resolvedPath` 落入:
```swift
items.append(.init(id: dep.installName, resolvedPath: nil,
                   state: .failed(message: "path unresolved"),
                   hasPriorityBoost: false))
```

Task 24 后 batch 含 `.failed` 即被保留,toolbar 永久 `hasFailures` 红徽,popover 充满"path unresolved"红 ✗ 行 —— 全是误报。

测试已经感知到这一点:
- `DylibPathResolverTests.swift:8-10`:"// Use /usr/lib/dyld because most dylibs live in the dyld shared cache and have no on-disk file on Apple Silicon Macs (e.g. libSystem.B.dylib). /usr/lib/dyld is a real on-disk file across macOS versions."
- `RuntimeEngineIndexStateTests` 用 `XCTSkipUnless` 给 Foundation 兜底。

测试用绕路、生产代码没修。功能 opt-in 一旦开启在 Apple Silicon Mac 上基本不可用。

**修法**(两选一):
- 让绝对路径也接受 `DyldUtilities.dyldSharedCacheImagePaths()` 返回集合的成员,Set 查找 O(1),列表本就缓存。
- 对绝对路径直接跳过 `fileExists` 检查,把判定权交给 `DyldUtilities.loadImage`,真正 `dlopen` 失败时再标 `.failed` —— 让"失败"项有意义。

---

## Nit

### Nit-1. 每批次 Cancel 按钮缺失,`cancelBatchRelay` 是死代码

**文件**: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift:282-311`

`cancelBatchRelay`(line 15)、Input 接线(line 181)、ViewModel `transform` → `coordinator.cancelBatch(id)` → `manager.cancelBatch(id)` 一路通到底,**全程无 `.accept(...)` callsite**。`outlineView(_:viewFor:item:)` 的批次行只渲染 Label,无任何按钮 / target-action / 点击转发。

Evolution 0002 第 521 行:*"Batch 行:标题由 reason 派生、`{completed}/{total}`,以及一个 cancel 按钮。点击 cancel 会触发 `cancelBatchRelay.accept(batchID)`。"*

用户多 batch 并发时(e.g. main exec + dlopen 进来的 framework),只能"Cancel All"丢掉所有进度,无法选择性取消单个慢 batch。

**修法**(两选一):
- (A) 实现 spec:在 cell 加一个 NSButton(SF Symbol `xmark.circle`,`accessoryBarAction` 风格),target-action 推 `batch.id` 到捕获的 relay。需要小型自定义 NSTableCellView 子类持有 batch id。
- (B) 删掉死路:relay / Input / route 全部移除,Evolution 0002 标记 per-batch cancel 为延后。

(A) 是正确选择 —— 基础设施已经全部就位,只缺一个按钮。

### Nit-2. Settings off→on 触发用错误 `reason`

**文件**: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift:277-290`

`handleSettingsChange` 的 off→on 分支:
```swift
if !wasEnabled && latest.isEnabled {
    documentDidOpen()
}
```

但 `documentDidOpen()` 硬编码 `reason: .appLaunch`(line 207)。

`RuntimeIndexingBatchReason.settingsEnabled` 在生产代码中**永远不会被构造** —— 全仓搜索只命中枚举定义本身。Popover 的 `title(for: .settingsEnabled) → "Settings enabled"` 分支不可达,用户切 Settings 时看到的标题是"App launch indexing",误导。

纯外观 bug,索引行为完全相同(同 root / 同 depth / 同 maxConcurrency)。

**修法**:抽 `private func startMainExecutableBatch(reason: RuntimeIndexingBatchReason)` helper,`documentDidOpen()` 传 `.appLaunch`,`handleSettingsChange` off→on 分支传 `.settingsEnabled`。

### Nit-3. `documentBatchIDs` 泄漏失败完成批次的 ID

**文件**: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift:135-158`

```swift
case .batchFinished(let finished):
    if finished.items.contains(where: { /* has .failed */ }) {
        if let idx = batches.firstIndex(where: { $0.id == finished.id }) {
            batches[idx] = finished
        }
        // ← 缺 documentBatchIDs.remove(finished.id)
    } else {
        batches.removeAll { $0.id == finished.id }
        documentBatchIDs.remove(finished.id)   // 仅清洁路径
    }
```

并行的 `.batchCancelled` arm 注释明确写"Cancellation always removes — user already acknowledged the outcome",从 `batchesRelay` 和 `documentBatchIDs` 都删。但失败保留分支只更新 `batches`,不清 `documentBatchIDs`。`clearFailedBatches()`(line 85-95)也只 filter `batchesRelay`,不动 `documentBatchIDs`。

后果:
- `documentBatchIDs` 在 Document 生命期单调增长(每个部分失败 batch +1)。
- `documentWillClose` 用 `documentBatchIDs` 派发 `cancelBatch`,每个泄漏 ID 落到 manager 的 `guard let state = activeBatches[id] else { return }` 短路 —— 多发若干 no-op Task。

实际影响 < 100 字节量级,但与代码注释自相矛盾。

**修法**(两处,共 ~5 行):
- 失败保留分支补 `documentBatchIDs.remove(finished.id)`(batch 在 manager 侧已 finalize,无论 UI 是否保留)。
- `clearFailedBatches()` 计算被清掉的 batches,从 `documentBatchIDs` 减。

---

## Pre-existing(P2 跟进)

### Pre-1. `isImageIndexed` 与 `loadImageForBackgroundIndexing` 路径规范化不对称

**文件**: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift:6-15`

(对应 implementation-review 的 I5,独立验证。)

`isImageIndexed(path:)` 用 `DyldUtilities.patchImagePathForDyld(path)` 规范化后查 cache,`loadImageForBackgroundIndexing(at:)` 用 raw path 写 cache。pre-existing `loadImage(at:)` 同样用 raw 写。

`patchImagePathForDyld` 仅在 `DYLD_ROOT_PATH` 设置时非 identity → 当前 macOS 主线休眠,**iOS Simulator runner 一启用立刻坏**:每个 `isImageIndexed` 永远 false,BFS 短路失效,`handleImageLoaded` 持续 spawn 新 batch,toolbar 转圈不停。

测试 `test_isImageIndexed_normalizesPath`(`RuntimeEngineIndexStateTests.swift:36-50`)的注释自己点出:"On most macOS hosts ... the raw and patched forms are identical and this test still pins the contract" —— 测试只 pin 契约不检查端到端工作。

**修法**(择一):
- 廉价:从 `isImageIndexed` 拿掉 patch,与 writer 的 raw 契约对齐,顺便审计 `isImageLoaded`。
- 彻底:在 `loadImageForBackgroundIndexing` / `loadImage(at:)` / 所有 cache writer 都加 patch,保留 `isImageIndexed` 的 patch。

绑 iOS Simulator 支持工作,本 PR 不阻塞。

---

## 与 implementation-review 的关系

| 本审查 | implementation-review (内部) | 备注 |
|--------|------------------------------|------|
| N2 | I3 | 独立验证,确认未在 PR 中修复 |
| N3 | I1 | 独立验证 + 补出 spec 规则太窄 |
| Pre-1 | I5 | 独立验证 |
| N1 | — | 新发现:N4 决议引发的循环引用 |
| N4 | — | 新发现:dyld shared cache 系统 framework 误判 |
| Nit-1 | — | 新发现:per-batch cancel 死代码 |
| Nit-2 | — | 新发现:`.settingsEnabled` 永远不构造 |
| Nit-3 | — | 新发现:`documentBatchIDs` 失败泄漏 |

internal review 的 I2 / I4 / I6 / 各 Minor 项未被 ultrareview 覆盖(范围或 prompt 差异),不矛盾。

---

## 优先级建议

1. **N1 + N4** 优先 —— 内存泄漏 + 功能在主流硬件上误报,改动都 ≤ 10 行。
2. **N2** 紧随 PR —— source switch 是真实用户路径,内部 review 已点名,可与 N1 一起做。
3. **N3 + Nit-1** 一起处理 —— spec 与代码契约对齐,要么实现要么删,留着只会越来越假。
4. **Nit-2 + Nit-3** 顺手 —— 总共不到 20 行,清掉死代码与轻微泄漏。
5. **Pre-1** 跟进 —— 绑 iOS Simulator 支持,P2。
